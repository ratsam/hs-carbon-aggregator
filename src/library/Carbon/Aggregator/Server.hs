{-# LANGUAGE ScopedTypeVariables #-}

module Carbon.Aggregator.Server

where

import Network.Socket hiding (socket)
import qualified Network.Socket as NS
import qualified Data.ByteString as B
import Control.Monad
import Control.Exception
import Control.Concurrent
import System.IO
import Control.Concurrent.STM
import Carbon
import Carbon.Decoder
import Carbon.Aggregator.Rules
import Carbon.Aggregator.Processor
import Data.Maybe

import Carbon.Codec.Pickle

type ServerHandler = Handle -> IO ()

-- iNADDR_ANY
runTCPServer :: ServerHandler -> (HostAddress, Int) -> IO ()
runTCPServer handler (host, port) = withSocketsDo $ bracket
    (bindPort host port)
    (\s -> do putStrLn "Wow-wow, shutting server down!"; sClose s)
    (forever . serve)
    where
        serve ssock = do
            (sock, _) <- acceptSafe ssock
            h <- socketToHandle sock ReadMode
            forkFinally (handler h) (\e -> do putStrLn "Client gone..."; print e; hClose h)

-- This is the only method related to Carbon. Should I extract everything else to dedicated module?
handlePlainTextConnection :: [Rule] -> TChan [MetricTuple] -> TVar BuffersManager -> ServerHandler
handlePlainTextConnection rules outchan tbm h = do
    putStrLn $ "Wow! such connection! Processing with " ++ (show $ length rules) ++ " rule(s)."
    hSetBuffering h LineBuffering
    loop
    where
        loop :: IO ()
        loop = do
            line <- B.hGetLine h
            putStrLn $ "Got the " ++ show line
            -- TODO: log connection? increment counter?
            let mm = decodePlainText line
            case mm of
                Just metric -> atomically $ do
                    mmetric' <- processAggregateT rules tbm metric
                    case mmetric' of
                        Just metric' -> writeTChan outchan [metric']
                        Nothing -> return ()
                Nothing -> return ()

            hEof <- hIsEOF h
            unless hEof loop

handlePickleConnection :: [Rule] -> TChan [MetricTuple] -> TVar BuffersManager -> ServerHandler
handlePickleConnection rules outchan tbm h = do
    putStrLn $ "Wow! such connection! Processing with " ++ (show $ length rules) ++ " rule(s)."
    hSetBuffering h NoBuffering
    loop
    where
        loop :: IO ()
        loop = do
            mmtuples <- readPickled h
            case mmtuples of
                Nothing -> putStrLn "Could not parse message"
                Just mtuples -> do
                    -- Break into smaller (independent but sequentional) transactions
                    outm <- atomically $ mapM (processAggregateT rules tbm) mtuples
                    atomically $ writeTChan outchan (catMaybes outm)

            hEof <- hIsEOF h
            unless hEof loop

createSocket :: HostAddress -> Int -> IO Socket
createSocket host port = do
  sock <- NS.socket AF_INET Stream 0
  setSocketOption sock ReuseAddr 1
  bindSocket sock $ SockAddrInet (fromIntegral port) host
  return sock

bindPort :: HostAddress -> Int -> IO Socket
bindPort host port = do
    sock <- createSocket host port
    listen sock (max 2048 maxListenQueue)
    return sock

acceptSafe :: Socket -> IO (Socket, SockAddr)
acceptSafe socket = loop
    where
        loop =
            accept socket `catch` \(_ :: IOException) -> do
                -- Sleep 1 second
                threadDelay 1000000
                loop
