
{-# LANGUAGE RebindableSyntax #-}

module Client 
  ( clientShell
  , clientBot
  , BotClient, mkBotClient, terminateBotClient
  ) where

import Prelude

import System.Timeout ( timeout )

import Control.Monad ( void, when, unless, forM_ )

import Control.Monad.Indexed ( (>>>=), ireturn )

import Control.Concurrent ( ThreadId, forkIO, threadDelay )
import Control.Concurrent.STM ( atomically )
import Control.Concurrent.STM.TMVar
  ( TMVar
  , newEmptyTMVarIO
  , takeTMVar, putTMVar
  , tryTakeTMVar )
import Control.Concurrent.STM.TVar 
  ( TVar
  , newTVarIO
  , readTVar, writeTVar, modifyTVar, swapTVar )

import Control.Concurrent.SimpleSession.Implicit 
  ( Session, Cap
  , Var, Z
  , request
  , recv, send
  , sel1, sel2, offer
  , close
  , enter, zero )

import Utility 
  ( ifThenElse
  , stm
  , trim
  , isValidUserName )
import Types 
  ( User, Message
  , Update(..), Request(..), Response(..)
  , ClientInit, ClientProtocol
  , Connection, unwrapConnection )

type TerminationFlag = TVar Bool

clientShell :: Connection -> IO ()
clientShell conn = do
  putStrLn "Enter your username:"
  userName <- trim <$> getLine
  if isValidUserName userName then do
    commNode <- spawnClientCommNode userName conn
    clientLoop userName commNode
  else do
    putStrLn "Invalid username!"
  putStrLn "End chat."
  where
    clientLoop :: User -> ClientCommNode -> IO ()
    clientLoop user commNode = do
      strCommand <- getUserInput True commNode
      case strCommand of
        "help" -> do
          putStrLn "Available commands: 'help', 'list', 'quit' or just type a message to send."
          clientLoop user commNode
        "list" -> do
          mkRequest commNode FetchUserList $ \(UserListResponse list) -> forM_ list putStrLn
          clientLoop user commNode
        "quit" -> do
          mkRequest commNode ShutdownServer $ const $ return ()
          putStrLn "Good bye!"
        msg -> do
          mkRequest commNode (SendMessage msg) $ const $ return ()
          clientLoop user commNode
    
    getUserInput :: Bool -> ClientCommNode -> IO String
    getUserInput showPrompt commNode = do
      when showPrompt $ putStr "> "
      mInput <- timeout 100 getLine
      case mInput of
        Just input -> return input
        Nothing -> do
          allUpdates <- getUpdates commNode
          case filter (/= NoUpdate) allUpdates of
            [] -> getUserInput False commNode
            updates -> do
              putStrLn ""
              forM_ updates $ \update -> case update of
                UserLeftChat usr -> putStrLn $ "> User left chat: " ++ usr
                NewMessage usr msg -> putStrLn $ usr ++ ": " ++ msg
                NoUpdate -> return ()
              getUserInput True commNode

data BotClient = BotClient
  { botName :: User
  , botTerminate :: TerminationFlag
  , botNoUpdateHandler :: TerminationFlag -> IO ()
  , botUserLeftHandler :: TerminationFlag -> User -> IO ()
  , botNewMessageHandler :: TerminationFlag -> User -> Message -> IO ()
  , botTerminateHandler :: IO ()
  }

mkBotClient :: User -- ^ The bots username.
            -> (TerminationFlag -> IO ()) -- ^ Executed when there are no updates.
            -> (TerminationFlag -> User -> IO ()) -- ^ Executed when a user leaves.
            -> (TerminationFlag -> User -> Message -> IO ()) -- ^ Excuted when a new message arives.
            -> IO () -- ^ Executed when the bot terminates. This may happen through the server or the bot itself.
            -> IO BotClient
mkBotClient userName noUpdate userLeft newMessage terminateHandler = do
  terminateVar <- newTVarIO False
  return $ BotClient
    { botName = userName
    , botTerminate = terminateVar
    , botNoUpdateHandler = noUpdate
    , botUserLeftHandler = userLeft
    , botNewMessageHandler = newMessage
    , botTerminateHandler = terminateHandler
    }

terminateBotClient :: BotClient -> IO ()
terminateBotClient bot = atomically $ writeTVar (botTerminate bot) True

clientBot :: Connection -> BotClient -> IO ()
clientBot conn bot = 
  void $ forkIO $ do
    commNode <- spawnClientCommNode (botName bot) conn
    clientLoop commNode
  where
    clientLoop :: ClientCommNode -> IO ()
    clientLoop commNode = do
      threadDelay 500
      terminate <- atomically $ readTVar (botTerminate bot)
      if terminate then do
        terminateCommNode commNode
        botTerminateHandler bot
      else do
        allUpdates <- getUpdates commNode
        case filter (/= NoUpdate) allUpdates of
          [] -> botNoUpdateHandler bot (botTerminate bot)
          updates -> forM_ updates $ \update -> case update of
            UserLeftChat usr -> botUserLeftHandler bot (botTerminate bot) usr
            NewMessage usr msg -> botNewMessageHandler bot (botTerminate bot) usr msg
            NoUpdate -> return ()
        ifTerminated commNode $ do
          terminateBotClient bot
          botTerminateHandler bot
        ifNotTerminated commNode $ do
          clientLoop commNode

mkRequest :: ClientCommNode -> Request -> (Response -> IO a) -> IO a
mkRequest commNode req respHandler = do
  resp <- atomically $ do
    putTMVar (commNodeCurrentRequest commNode) req
    takeTMVar (commNodeCurrentResponse commNode)
  respHandler resp

getUpdates :: ClientCommNode -> IO [Update]
getUpdates commNode = atomically $ swapTVar (commNodeUpdates commNode) []

ifTerminated :: ClientCommNode -> IO () -> IO ()
ifTerminated commNode termHandler = do
  isTerminated <- atomically $ readTVar (commNodeTerminated commNode)
  when isTerminated termHandler

ifNotTerminated :: ClientCommNode -> IO () -> IO ()
ifNotTerminated commNode handler = do
  isTerminated <- atomically $ readTVar (commNodeTerminated commNode)
  unless isTerminated handler
  
terminateCommNode :: ClientCommNode -> IO ()
terminateCommNode commNode = do
  atomically $ writeTVar (commNodeTerminated commNode) True

data ClientCommNode = ClientCommNode
  { commNodeUpdates :: TVar [Update]
  , commNodeCurrentRequest :: TMVar Request
  , commNodeCurrentResponse :: TMVar Response
  , commNodeTerminated :: TVar Bool
  , commNodeThreadId :: ThreadId
  , commNodeUserName :: User
  }

spawnClientCommNode :: User
                    -> Connection
                    -> IO ClientCommNode
spawnClientCommNode userName conn = do
  
  requestVar <- newEmptyTMVarIO
  responseVar <- newEmptyTMVarIO
  updatesVar <- newTVarIO []
  terminateVar <- newTVarIO False
  
  commThreadId <- forkIO $ request (unwrapConnection conn) 
                         $ commThread terminateVar requestVar responseVar updatesVar
  
  return $ ClientCommNode
    { commNodeCurrentRequest = requestVar
    , commNodeCurrentResponse = responseVar
    , commNodeUpdates = updatesVar
    , commNodeTerminated = terminateVar
    , commNodeThreadId = commThreadId
    , commNodeUserName = userName
    }
  where
    commThread :: TVar Bool 
               -> TMVar Request -> TMVar Response -> TVar [Update]
               -> Session (Cap () (ClientInit (ClientProtocol (Var Z)))) () ()
    commThread terminateVar requestVar responseVar updatesVar = do
      send userName
      enter -- Enter the recursive loop
      commThreadLoop terminateVar requestVar responseVar updatesVar
      where -- TODO: Bind annotations
        (>>=) :: Session i j a -> (a -> Session j k b) -> Session i k b
        (>>=) = (>>>=)
        (>>) :: Session i j a -> Session j k b -> Session i k b
        a >> b = a >>= const b
        return :: a -> Session i i a
        return = ireturn
    
    commThreadLoop :: TVar Bool 
                   -> TMVar Request -> TMVar Response -> TVar [Update]
                   -> Session (Cap ((ClientProtocol (Var Z)), ()) (ClientProtocol (Var Z))) () ()
    commThreadLoop terminateVar requestVar responseVar updatesVar = do
      offer ((stm $ writeTVar terminateVar True) >> close) $ do
        -- Termination phase
        terminated <- stm $ readTVar terminateVar
        if terminated then do
          sel1
          close
        else do
          sel2
          -- Update phase
          updates <- recv
          stm $ modifyTVar updatesVar (updates ++)
          -- Request phase
          mRequest <- stm $ tryTakeTMVar requestVar
          case mRequest of
            Just request -> do
              send request
              response <- recv
              stm $ putTMVar responseVar response
            Nothing -> do
              send NoRequest
              EmptyResponse <- recv
              return ()
          -- Recursive step
          zero
          commThreadLoop terminateVar requestVar responseVar updatesVar
      where -- TODO: Bind annotations
        (>>=) :: Session i j a -> (a -> Session j k b) -> Session i k b
        (>>=) = (>>>=)
        (>>) :: Session i j a -> Session j k b -> Session i k b
        a >> b = a >>= const b
        return :: a -> Session i i a
        return = ireturn
        fail :: String -> Session i j a
        fail = error