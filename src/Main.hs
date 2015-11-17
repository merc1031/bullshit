module Main where
import Data.Maybe
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad
import Data.List
import Foreign.Marshal.Alloc
import GHC.Ptr
import System.Directory
import System.Environment (getArgs)
import System.FilePath
import System.IO
import System.Posix.Files

bufSize :: Int
bufSize = 464

worker :: TChan FilePath -> TVar Int -> Int -> IO ()
worker chan count _ = do
  bufs <- mapConcurrently (\_ -> return $ allocaBytes bufSize) [1..101]
  void $ async $ do
    putStrLn "worker started"
    forever $ do
        path' <- atomically $ readTChan chan
        paths <- fmap catMaybes $ atomically $ mapM (\i -> do
                                                r <- tryReadTChan chan
                                                case r of
                                                  Nothing -> return $ Nothing
                                                  Just r' -> return $ Just (i, r')
                                                    ) [1..100]
        forM_ ((0,path'):paths) $ \(idx, path) -> do
            stat <- getFileStatus path
            when (isDirectory stat) (feedWorker chan path)
            when (isRegularFile stat) $ do
                (bufs !! idx) $ \buf -> withFile path ReadMode (readContents buf)
                atomically $ modifyTVar' count (+1)

feedWorker :: TChan FilePath -> String -> IO ()
feedWorker c path = do
  contents <- map (path </>) . filter (not . isPrefixOf ".") <$> getDirectoryContents path
  atomically $ mapM_ (writeTChan c) contents
  return ()

readContents :: GHC.Ptr.Ptr a -> Handle -> IO ()
readContents buf h = do
  hSetBinaryMode h True
  hSetBuffering h $ BlockBuffering $ Just bufSize
  _ <- hGetBufNonBlocking h buf bufSize
  return ()

timer :: TVar Int -> IO ()
timer count = do
  totalV <- newTVarIO 0
  void $ async $ forever $ do
    threadDelay 1000000
    (latest, total) <- atomically $ do
      x <- readTVar count
      writeTVar count 0
      y <- readTVar totalV
      modifyTVar' totalV (+x)
      return (x, x+y)
    putStrLn $ "Loaded " ++ show total ++ ", " ++ show latest ++ "/second"

main :: IO ()
main = do
  args <- getArgs
  chan <- newTChanIO
  count <- newTVarIO 0
  _ <- timer count
  case args of
    [path] -> atomically $ writeTChan chan path
    _      -> atomically $ writeTChan chan "."
  mapM_ (worker chan count) [1..100]

  _ <- getLine
  return ()
