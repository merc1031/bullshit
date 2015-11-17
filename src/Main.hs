module Main where
import Control.Concurrent
import Control.Concurrent.Async
import Control.Monad
import Data.List
import Data.Time.Clock
import Foreign.Marshal.Alloc
import GHC.Ptr
import System.Directory
import System.Environment (getArgs)
import System.FilePath
import System.IO
import System.Posix.Files

bufSize :: Int
bufSize = 464

worker :: Chan FilePath -> Int -> IO ()
worker chan _ = allocaBytes bufSize $ \buf ->
  forever $ do
    path <- readChan chan
    contents <- map (path </>) . filter (not . isPrefixOf ".") <$> getDirectoryContents path
    statted <- zip contents <$> mapConcurrently getFileStatus contents
    let (dirs, files) = partition (isDirectory . snd) statted
    writeList2Chan chan $ map fst dirs
    unless (null files) $ void $ mapConcurrently (readContents buf . fst) files
    return ()

readContents :: GHC.Ptr.Ptr a -> FilePath -> IO ()
readContents buf path = withFile path ReadMode $ \h -> do
  hSetBinaryMode h True
  hSetBuffering h $ BlockBuffering $ Just bufSize
  _ <- hGetBuf h buf bufSize
  return ()

mark :: Int
mark = 1000

timer :: Chan FilePath -> Int -> UTCTime -> IO ()
timer mon total time = do
  _ <- readChan mon
  if total `mod` mark == 0
    then do
      newtime <- getCurrentTime
      let diff = diffUTCTime newtime time
          rate = truncate $ fromIntegral mark / diff :: Integer
      putStrLn $ show total ++ " total, " ++ show rate ++ " per second"
      timer mon (total + 1) newtime
    else
      timer mon (total + 1) time

main :: IO ()
main = do
  args <- getArgs
  chan <- newChan
  monitor <- dupChan chan
  time <- getCurrentTime
  _ <- forkIO $ timer monitor 1 time
  case args of
    [path] -> writeChan chan path
    _      -> writeChan chan "."
  concurrency <- getNumCapabilities
  _ <- mapConcurrently (worker chan) [1..concurrency*3]
  return ()
