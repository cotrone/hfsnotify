--
-- Copyright (c) 2012 Mark Dittmer - http://www.markdittmer.org
-- Developed for a Google Summer of Code project - http://gsoc2012.markdittmer.org
--
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE OverloadedStrings #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module System.FSNotify.Linux (
  FileListener(..)
  , NativeManager
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception.Safe as E
import Control.Monad
import qualified Data.ByteString as BS
import Data.Function
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.String
import Data.Time.Clock (UTCTime, NominalDiffTime, addUTCTime, secondsToNominalDiffTime)
import Data.Time.Clock.POSIX
import qualified GHC.Foreign as F
import GHC.IO.Encoding (getFileSystemEncoding)
import Prelude hiding (FilePath)
import System.Directory (canonicalizePath)
import System.IO.Error (isDoesNotExistErrorType, ioeGetErrorType)
import System.FSNotify.Find
import System.FSNotify.Listener
import System.FSNotify.Types
import System.FilePath (FilePath, (</>))
import qualified System.INotify as INo
import System.Posix.ByteString (RawFilePath)
import System.Posix.Directory.ByteString (openDirStream, readDirStream, closeDirStream)
import System.Posix.Files (getFileStatus, isDirectory, modificationTimeHiRes)


data INotifyListener = INotifyListener { listenerINotify :: INo.INotify }

type NativeManager = INotifyListener

data EventVarietyMismatchException = EventVarietyMismatchException deriving (Show, Typeable)
instance Exception EventVarietyMismatchException


fsnEvents :: RawFilePath -> UTCTime -> INo.Event -> IO [Event]
fsnEvents basePath' timestamp (INo.Attributes (boolToIsDirectory -> isDir) (Just raw)) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [ModifiedAttributes (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp (INo.Modified (boolToIsDirectory -> isDir) (Just raw)) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [Modified (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp (INo.Closed (boolToIsDirectory -> isDir) (Just raw) True) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [CloseWrite (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp (INo.Created (boolToIsDirectory -> isDir) raw) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [Added (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp (INo.MovedOut (boolToIsDirectory -> isDir) raw _cookie) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [Removed (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp (INo.MovedIn (boolToIsDirectory -> isDir) raw _cookie) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [Added (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp (INo.Deleted (boolToIsDirectory -> isDir) raw) = do
  basePath <- fromRawFilePath basePath'
  fromHinotifyPath raw >>= \name -> return [Removed (basePath </> name) timestamp isDir]
fsnEvents basePath' timestamp INo.DeletedSelf = do
  basePath <- fromRawFilePath basePath'
  return [WatchedDirectoryRemoved basePath timestamp IsDirectory]
fsnEvents _ _ INo.Ignored = return []
fsnEvents basePath' timestamp inoEvent = do
  basePath <- fromRawFilePath basePath'
  return [Unknown basePath timestamp IsFile (show inoEvent)]

handleInoEvent :: ActionPredicate -> EventCallback -> RawFilePath -> MVar Bool -> INo.Event -> IO ()
handleInoEvent actPred callback basePath watchStillExistsVar inoEvent = do
  when (INo.DeletedSelf == inoEvent) $ modifyMVar_ watchStillExistsVar $ const $ return False

  currentTime <- getCurrentTime
  events <- fsnEvents basePath currentTime inoEvent
  forM_ events $ \event -> when (actPred event) $ callback event

varieties :: [INo.EventVariety]
varieties = [INo.Create, INo.Delete, INo.MoveIn, INo.MoveOut, INo.Attrib, INo.Modify, INo.CloseWrite, INo.DeleteSelf]

instance FileListener INotifyListener () where
  initSession _ = E.handle (\(e :: IOException) -> return $ Left $ fromString $ show e) $ do
    inotify <- INo.initINotify
    return $ Right $ INotifyListener inotify

  killSession (INotifyListener {listenerINotify}) = INo.killINotify listenerINotify

  listen _conf (INotifyListener {listenerINotify}) path actPred callback = do
    rawPath <- toRawFilePath path
    canonicalRawPath <- canonicalizeRawDirPath rawPath
    watchStillExistsVar <- newMVar True
    hinotifyPath <- rawToHinotifyPath canonicalRawPath
    wd <- INo.addWatch listenerINotify varieties hinotifyPath (handleInoEvent actPred callback canonicalRawPath watchStillExistsVar)
    return $
      modifyMVar_ watchStillExistsVar $ \wse -> do
        when wse $ INo.removeWatch wd
        return False

  listenRecursive _conf listener initialPath actPred callback = do
    -- wdVar stores the list of created watch descriptors. We use it to
    -- cancel the whole recursive listening task.
    --
    -- To avoid a race condition (when a new watch is added right after
    -- we've stopped listening), we replace the MVar contents with Nothing
    -- to signify that the listening task is cancelled, and no new watches
    -- should be added.
    wdVar <- newMVar (Just mempty)

    -- movedDirectories stores watched directories that were moved out of
    -- a watched directory, these are removed after they have been moved
    -- for movedCookieTimeout and not move in to a watched directory
    let
      movedCookieTimeout = secondsToNominalDiffTime 1
      movedFilterDelay = 1000000 -- 1 second
    movedDirectories <- newMVar Map.empty

    filterThread <- async $ forever $ do
      threadDelay movedFilterDelay
      filterMovedDirs movedDirectories movedCookieTimeout

    let
      removeWatches wds = forM_ wds $ \watched ->
        modifyMVar_ (watchedStillExists watched) $ \wse -> do
          let wd = watchedDescriptor watched
          when wse $
            handle (\(e :: SomeException) -> putStrLn ("Error removing watch: " <> show wd <> " (" <> show e <> ")"))
                   (INo.removeWatch wd)
          return False

      stopListening = do
        cancel filterThread
        modifyMVar_ wdVar $ \x -> maybe (return ()) removeWatches x >> return Nothing

    -- Add watches to this directory plus every sub-directory
    rawInitialPath <- toRawFilePath initialPath
    rawCanonicalInitialPath <- canonicalizeRawDirPath rawInitialPath
    watchDirectoryRecursively listener wdVar movedDirectories actPred callback True rawCanonicalInitialPath
    traverseAllDirs rawCanonicalInitialPath $ \subPath ->
      watchDirectoryRecursively listener wdVar movedDirectories actPred callback False subPath

    return stopListening

data WatchedDirectory = WatchedDirectory {
  watchedDescriptor :: INo.WatchDescriptor
, watchedStillExists :: MVar Bool -- ^ Set to False when the watch is removed
, watchedPath :: MVar RawFilePath -- ^ The path of the directory being watched
}

type RecursiveWatches = MVar (Maybe (HashMap RawFilePath WatchedDirectory))

-- | Remove a watched directory from the list of watched directories
removeWatchedDir :: RecursiveWatches -> RawFilePath -> IO (Maybe WatchedDirectory)
removeWatchedDir watchedDirectories dir =
  modifyMVar watchedDirectories $ return . maybe (Nothing, Nothing) (\watches ->  (Just $ HashMap.delete dir watches, HashMap.lookup dir watches))

-- | Directories moved out of a watched directory and the time they were moved
type MovedDirectories = MVar (Map INo.Cookie (UTCTime, WatchedDirectory))

addMovedDir :: MovedDirectories -> INo.Cookie -> WatchedDirectory -> IO ()
addMovedDir movedDirectories cookie dirRef = do
  movedTime <- getCurrentTime
  modifyMVar movedDirectories $ \m -> return (Map.insert cookie (movedTime, dirRef) m, ())

removeMovedDir :: MovedDirectories -> INo.Cookie -> IO (Maybe WatchedDirectory)
removeMovedDir movedDirectories cookie =
  modifyMVar movedDirectories $ \m -> return (Map.delete cookie m, snd <$> Map.lookup cookie m)

filterMovedDirs :: MovedDirectories -> NominalDiffTime -> IO ()
filterMovedDirs movedDirectories offset = do
  currentTime <- getCurrentTime
  modifyMVar movedDirectories $ \m -> return (Map.filter (\(movedTime, _) -> addUTCTime offset movedTime >= currentTime) m, ())

watchDirectoryRecursively :: INotifyListener -> RecursiveWatches -> MovedDirectories -> ActionPredicate -> EventCallback -> Bool -> RawFilePath -> IO ()
watchDirectoryRecursively listener@(INotifyListener {listenerINotify}) wdVar movedDirectories actPred callback isRootWatchedDir rawFilePath = do
  modifyMVar_ wdVar $ \case
    Nothing -> return Nothing
    Just wds -> do
      watchStillExistsVar <- newMVar True
      hinotifyPath <- rawToHinotifyPath rawFilePath
      dirRef <- newMVar hinotifyPath
      let hanlder = handleRecursiveEvent movedDirectories dirRef actPred callback watchStillExistsVar isRootWatchedDir listener wdVar
      -- Attempt to add a watch to the directory, if the directory doesn't exist
      -- because it was deleted or moved after the event is fired then the addWatch will throw an exception
      ewd <- try $ INo.addWatch listenerINotify varieties hinotifyPath hanlder
      case ewd of
        Left e
          | isDoesNotExistErrorType (ioeGetErrorType e) -> do
              return $ Just wds
          | otherwise -> throwIO e
        Right wd -> return $ Just $ HashMap.insert rawFilePath (WatchedDirectory wd watchStillExistsVar dirRef) wds

handleRecursiveEvent :: MovedDirectories -> MVar RawFilePath -> ActionPredicate -> EventCallback -> MVar Bool -> Bool -> INotifyListener -> RecursiveWatches -> INo.Event -> IO ()
handleRecursiveEvent movedDirectories dirRef actPred callback watchStillExistsVar isRootWatchedDir listener wdVar event = do
  case event of
    INo.DeletedSelf ->
      -- The watched directory was removed, mark the watch as already removed
      modifyMVar_ watchStillExistsVar $ const $ return False
    (INo.Created True hiNotifyPath) ->
      -- A new directory was created, add watches to it
      watchNewDirectory hiNotifyPath
    INo.MovedOut True hiNotifyPath cookie -> do
      baseDir <- readMVar dirRef
      let movedOutDir = baseDir <//> hiNotifyPath
      -- Directory was moved out, empty base directory reference because any events from this directory would be from an unknown location
      removeWatchedDir wdVar movedOutDir >>= \case
        Nothing -> return () -- Something went wrong, the directory was moved out but there is no reference to it
        Just movedOutDirRef -> do
          -- 
          _ <- takeMVar $ watchedPath movedOutDirRef
          -- Add the base directory reference to a map with the cookie as a key so it can be retrieved if the directory is moved into another directory that is being watched
          addMovedDir movedDirectories cookie movedOutDirRef
    INo.MovedIn True hiNotifyPath cookie -> do
      baseDir <- readMVar dirRef
      let movedInDir = baseDir <//> hiNotifyPath
      -- Directory was moved in, add the base directory reference back to the map
      removeMovedDir movedDirectories cookie >>= \case
        Just movedWatch ->
          -- The directory was moved out of a watched directory and already has watches set up
          -- Only need to update the directory reference
          putMVar (watchedPath movedWatch) movedInDir
        Nothing -> 
          -- The directory was moved in from an unknown location, set up watches for it like a new directory
          -- A new directory was created, so add recursive inotify watches to it
          watchNewDirectory hiNotifyPath
    _ -> return ()

  -- Forward the event. Ignore a DeletedSelf if we're not on the root directory,
  -- since the watch above us will pick up the delete of that directory.
  case event of
    INo.DeletedSelf | not isRootWatchedDir -> return ()
    _ -> do
      baseDir <- readMVar dirRef
      handleInoEvent actPred callback baseDir watchStillExistsVar event
  where
    watchNewDirectory hInotifyPath = do
      baseDir <- readMVar dirRef
      -- A new directory was created, so add recursive inotify watches to it
      rawDirPath <- rawFromHinotifyPath hInotifyPath
      let newRawDir = baseDir <//> rawDirPath
      timestampBeforeAddingWatch <- getPOSIXTime
      watchDirectoryRecursively listener wdVar movedDirectories actPred callback False newRawDir

      newDir <- fromRawFilePath newRawDir

      -- Find all files/folders that might have been created *after* the timestamp, and hence might have been
      -- missed by the watch
      -- TODO: there's a chance of this generating double events, fix
      files <- find False newDir -- TODO: expose the ability to set followSymlinks to True?
      forM_ files $ \newPath -> do
        fileStatus <- getFileStatus newPath
        let modTime = modificationTimeHiRes fileStatus
        when (modTime > timestampBeforeAddingWatch) $ do
          let isDir = if isDirectory fileStatus then IsDirectory else IsFile
          let addedEvent = (Added (newDir </> newPath) (posixSecondsToUTCTime timestampBeforeAddingWatch) isDir)
          when (actPred addedEvent) $ callback addedEvent

-- * Util

canonicalizeRawDirPath :: RawFilePath -> IO RawFilePath
canonicalizeRawDirPath p = fromRawFilePath p >>= canonicalizePath >>= toRawFilePath

-- | Same as </> but for RawFilePath
-- TODO: make sure this is correct or find in a library
(<//>) :: RawFilePath -> RawFilePath -> RawFilePath
x <//> y = x <> "/" <> y

traverseAllDirs :: RawFilePath -> (RawFilePath -> IO ()) -> IO ()
traverseAllDirs dir cb = traverseAll dir $ \subPath ->
  -- TODO: wish we didn't need fromRawFilePath here
  -- TODO: make sure this does the right thing with symlinks
  fromRawFilePath subPath >>= getFileStatus >>= \case
    (isDirectory -> True) -> cb subPath >> return True
    _ -> return False

traverseAll :: RawFilePath -> (RawFilePath -> IO Bool) -> IO ()
traverseAll dir cb = bracket (openDirStream dir) closeDirStream $ \dirStream ->
  fix $ \loop -> do
    readDirStream dirStream >>= \case
      x | BS.null x -> return ()
      "." -> loop
      ".." -> loop
      subDir -> flip finally loop $ do
        -- TODO: canonicalize?
        let fullSubDir = dir <//> subDir
        shouldRecurse <- cb fullSubDir
        when shouldRecurse $ traverseAll fullSubDir cb

boolToIsDirectory :: Bool -> EventIsDirectory
boolToIsDirectory False = IsFile
boolToIsDirectory True = IsDirectory

toRawFilePath :: FilePath -> IO BS.ByteString
toRawFilePath fp = do
  enc <- getFileSystemEncoding
  F.withCString enc fp BS.packCString

fromRawFilePath :: BS.ByteString -> IO FilePath
fromRawFilePath bs = do
  enc <- getFileSystemEncoding
  BS.useAsCString bs (F.peekCString enc)

#if MIN_VERSION_hinotify(0, 3, 10)
fromHinotifyPath :: BS.ByteString -> IO FilePath
fromHinotifyPath = fromRawFilePath

rawToHinotifyPath :: BS.ByteString -> IO BS.ByteString
rawToHinotifyPath = return

rawFromHinotifyPath :: BS.ByteString -> IO BS.ByteString
rawFromHinotifyPath = return
#else
fromHinotifyPath :: FilePath -> IO FilePath
fromHinotifyPath = return

rawToHinotifyPath :: BS.ByteString -> IO FilePath
rawToHinotifyPath = fromRawFilePath

rawFromHinotifyPath :: FilePath -> IO BS.ByteString
rawFromHinotifyPath = toRawFilePath
#endif
