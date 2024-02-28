
import System.Directory
import System.FilePath
import Control.Monad
import System.FSNotify
import Data.IORef
import Control.Concurrent (threadDelay)

main :: IO ()
main = do
  test1
  test2

data Event' =
    Added' { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory }
  | Modified' { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory }
  | ModifiedAttributes' { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory }
  | Removed' { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory }
  | WatchedDirectoryRemoved'  { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory }
  -- ^ Note: Linux-only
  | CloseWrite'  { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory }
  -- ^ Note: Linux-only
  | Unknown'  { eventPath' :: FilePath, eventIsDirectory' :: EventIsDirectory, eventString' :: String }
  -- ^ Note: Linux-only
  deriving (Eq, Show)

toEvent' :: FilePath -> Event -> Event'
toEvent' prefix event =
  case event of
    (Added p _ isDir) -> Added' (makeRelative prefix p) isDir
    (Modified p _ isDir) -> Modified' (makeRelative prefix p) isDir
    (ModifiedAttributes p _ isDir) -> ModifiedAttributes' (makeRelative prefix p) isDir
    (Removed p _ isDir) -> Removed' (makeRelative prefix p) isDir
    (WatchedDirectoryRemoved p _ isDir) -> WatchedDirectoryRemoved' (makeRelative prefix p) isDir
    (CloseWrite p _ isDir) -> CloseWrite' (makeRelative prefix p) isDir
    (Unknown p _ isDir s) -> Unknown' (makeRelative prefix p) isDir s

-- Test that directory renames don't cause wrong events to be emitted
-- to the old directory path 
test1 :: IO ()
test1 = do
  currentDirectory <- getCurrentDirectory
  let expectedEvents = [
            Added' {eventPath' = "subdir/foo", eventIsDirectory' = IsDirectory}
          , Removed' {eventPath' = "subdir/foo", eventIsDirectory' = IsDirectory}
        ]

  removeDirectoryIfPresent testDir
  createDirectory testDir

  removeDirectoryIfPresent testDir2
  createDirectory testDir2

  eventsRef <- newIORef [] 
  withManagerConf defaultConfig $ \mgr -> do
    stop <- watchTree mgr testDir (const True) $ \ev -> atomicModifyIORef' eventsRef (\evs -> ((evs ++ [ev]), ()))

    threadDelay 100
    createDirectory dir1
    threadDelay 100
    renameDirectory dir1 dir2
    threadDelay 100
    writeFile fp2 "hello\n"
    threadDelay 1000000
    events <- fmap (map (toEvent' currentDirectory)) $ readIORef eventsRef
    when (events /= expectedEvents) $ do
      putStrLn $ "test1 expected events:" <> show expectedEvents
      putStrLn $ "test1 actual events:" <> show events
    stop
  
    pure ()
  removeDirectoryIfPresent testDir
  removeDirectoryIfPresent testDir2
  where
    testDir, testDir2, dir1, dir2, fp2 :: FilePath
    testDir = "subdir"
    testDir2 = "subdir2"
    dir1 = testDir </> "foo"
    dir2 = testDir2 </> "bar"
    fp2 = dir2 </> "baz"

-- Test that directory renames don't cause wrong events to be emitted
-- using the old directory path 
test2 :: IO ()
test2 = do
  currentDirectory <- getCurrentDirectory
  let expectedEvents = [
          Added' {eventPath' = "subdir/foo", eventIsDirectory' = IsDirectory}
        , Removed' {eventPath' = "subdir/foo", eventIsDirectory' = IsDirectory}
        , Added' {eventPath' = "subdir/bar", eventIsDirectory' = IsDirectory}
        , Added' {eventPath' = "subdir/bar/baz", eventIsDirectory' = IsFile}
        , Modified' {eventPath' = "subdir/bar/baz", eventIsDirectory' = IsFile}
        , CloseWrite' {eventPath' = "subdir/bar/baz", eventIsDirectory' = IsFile}
        ]
  removeDirectoryIfPresent testDir
  createDirectory testDir

  eventsRef <- newIORef [] 
  withManagerConf defaultConfig $ \mgr -> do
    stop <- watchTree mgr testDir (const True) $ \ev -> atomicModifyIORef' eventsRef (\evs -> ((evs ++ [ev]), ()))

    threadDelay 100
    createDirectory dir1
    threadDelay 100
    renameDirectory dir1 dir2
    threadDelay 100
    writeFile fp "hello\n"
    threadDelay 1000000
    events <- fmap (map (toEvent' currentDirectory)) $ readIORef eventsRef
    when (events /= expectedEvents) $ do
      putStrLn $ "test2 expected events:" <> show expectedEvents
      putStrLn $ "test2 actual events:" <> show events
    stop
  
    pure ()
  removeDirectoryIfPresent testDir
  where
    testDir, dir1, dir2, fp :: FilePath
    testDir = "subdir"
    dir1 = testDir </> "foo"
    dir2 = testDir </> "bar"
    fp = dir2 </> "baz"

removeDirectoryIfPresent :: FilePath -> IO ()
removeDirectoryIfPresent dir = do
  exists <- doesDirectoryExist dir
  when exists $ removeDirectoryRecursive dir