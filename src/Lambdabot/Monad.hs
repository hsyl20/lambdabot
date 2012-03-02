{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
module Lambdabot.Monad
    ( IRCRState(..), IRCRWState(..), IRCError(..)
    , Callback, OutputFilter
    , ChanName, mkCN, getCN
    
    , LB(..), lbIO, evalLB
    
    , send, addServer, remServer, addServer'
    
    , handleIrc, catchIrc
    ) where

import           Lambdabot.IRC (IrcMessage)
import           Lambdabot.Module
import qualified Lambdabot.Message as Msg
import qualified Lambdabot.Shared  as S
import           Lambdabot.Signals
import           Lambdabot.Util

import Prelude hiding           (mod, catch)

import System.IO

#ifndef mingw32_HOST_OS
import System.Posix.Signals
#endif

import Data.Char
import Data.IORef               (newIORef, IORef, readIORef, writeIORef)
import Data.Map (Map)
import qualified Data.Map as M hiding (Map)

import Control.Concurrent (MVar, ThreadId)
import Control.Exception
import Control.Monad.Error (MonadError (..))
import Control.Monad.Reader
import Control.Monad.State

------------------------------------------------------------------------
--
-- Lambdabot state
--

-- | Global read-only state.
data IRCRState
  = IRCRState {
        ircMainThread  :: ThreadId,
        ircInitDoneMVar:: MVar (),
        ircQuitMVar    :: MVar ()
        -- ^This is a mildly annoying hack.  In order to prevent the program
        -- from closing immediately, we have to keep the main thread alive, but
        -- the obvious infinite-MVar-wait technique doesn't work - the garbage
        -- collector helpfully notices that the MVar is dead, kills the main
        -- thread (which will never wake up, so why keep it around), thus
        -- terminating the program.  Behold the infinite wisdom that is the
        -- Glasgow FP group.
  }

type Callback = IrcMessage -> LB ()

type OutputFilter = Msg.Nick -> [String] -> LB [String]

-- | Global read\/write state.
data IRCRWState = IRCRWState {
        ircServerMap       :: Map String (String, IrcMessage -> LB ()),
        ircPrivilegedUsers :: Map Msg.Nick Bool,
        ircIgnoredUsers    :: Map Msg.Nick Bool,

        ircChannels        :: Map ChanName String,
            -- ^ maps channel names to topics

        ircModules         :: Map String ModuleRef,
        ircCallbacks       :: Map String [(String,Callback)],
        ircOutputFilters   :: [(String,OutputFilter)],
            -- ^ Output filters, invoked from right to left

        ircCommands        :: Map String ModuleRef,
        ircPrivCommands    :: [String],
        ircStayConnected   :: !Bool,
        ircDynLoad         :: S.DynLoad,
        ircOnStartupCmds   :: [String],
        ircPlugins         :: [String]
    }

newtype ChanName = ChanName Msg.Nick -- always lowercase
  deriving (Eq, Ord)

instance Show ChanName where show (ChanName x) = show x

-- | only use the "smart constructor":
mkCN :: Msg.Nick -> ChanName
mkCN = ChanName . liftM2 Msg.Nick Msg.nTag (map toLower . Msg.nName)

getCN :: ChanName -> Msg.Nick
getCN (ChanName n) = n

-- The virtual chat system.
--
-- The virtual chat system sits between the chat drivers and the rest of
-- Lambdabot.  It provides a mapping between the String server "tags" and
-- functions which are able to handle sending messages.
--
-- When a message is recieved, the chat module is expected to call
-- `LMain.received'.  This is not ideal.

addServer :: String -> (IrcMessage -> LB ()) -> ModuleT mod LB ()
addServer tag sendf = do
    s <- get
    let svrs = ircServerMap s
    name <- getName
    case M.lookup tag svrs of
        Nothing -> put (s { ircServerMap = M.insert tag (name,sendf) svrs})
        Just _ -> fail $ "attempted to create two servers named " ++ tag

-- This is a crutch until all the servers are pluginized.
addServer' :: String -> (IrcMessage -> LB ()) -> LB ()
addServer' tag sendf = do
    s <- get
    let svrs = ircServerMap s
    case M.lookup tag svrs of
        Nothing -> put (s { ircServerMap = M.insert tag ("<core>",sendf) svrs})
        Just _ -> fail $ "attempted to create two servers named " ++ tag

remServer :: String -> LB ()
remServer tag = do
    s <- get
    let svrs = ircServerMap s
    case M.lookup tag svrs of
        Just _ -> do let svrs' = M.delete tag svrs
                     main <- asks ircMainThread
                     when (M.null svrs') $ io $ throwTo main (ErrorCall "all servers detached")
                     put (s { ircServerMap = svrs' })
        Nothing -> fail $ "attempted to delete nonexistent servers named " ++ tag

send :: IrcMessage -> LB ()
send msg = do
    s <- gets ircServerMap
    case M.lookup (Msg.server msg) s of
        Just (_, sendf) -> sendf msg
        Nothing -> io $ hPutStrLn stderr $ "sending message to bogus server: " ++ show msg


-- ---------------------------------------------------------------------
--
-- The LB (LambdaBot) monad
--

-- | The IRC Monad. The reader transformer holds information about the
--   connection to the IRC server.
--
-- instances Monad, Functor, MonadIO, MonadState, MonadError


newtype LB a = LB { runLB :: ReaderT (IRCRState,IORef IRCRWState) IO a }
    deriving (Monad,Functor,MonadIO)

-- Actually, this isn't a reader anymore
instance MonadReader IRCRState LB where
    ask   = LB $ asks fst
    local = error "You are not supposed to call local"

instance MonadState IRCRWState LB where
    get = LB $ do
        ref <- asks snd
        lift $ readIORef ref
    put x = LB $ do
        ref <- asks snd
        lift $ writeIORef ref x

-- And now a MonadError instance to map IRCErrors to MonadError in LB,
-- so throwError and catchError "just work"
instance MonadError IRCError LB where
  throwError (IRCRaised e)    = io $ throwIO e
  throwError (SignalCaught e) = io $ evaluate (throw $ SignalException e)
  m `catchError` h = lbIO $ \conv -> (conv m
              `catch` \(SignalException e) -> conv $ h $ SignalCaught e)
              `catch` \e -> conv $ h $ IRCRaised e

-- A type for handling both Haskell exceptions and external signals
data IRCError = IRCRaised SomeException | SignalCaught Signal

instance Show IRCError where
    show (IRCRaised    e) = show e
    show (SignalCaught s) = show s

-- lbIO return :: LB (LB a -> IO a)
-- CPS to work around predicativiy of haskell's type system.
lbIO :: ((forall a. LB a -> IO a) -> IO b) -> LB b
lbIO k = LB . ReaderT $ \r -> k (\(LB m) -> m `runReaderT` r)

-- | run a computation in the LB monad
evalLB :: LB a -> IRCRState -> IRCRWState -> IO a
evalLB (LB lb) rs rws = do
    ref  <- newIORef rws
    lb `runReaderT` (rs,ref)

-- May wish to add more things to the things caught, or restructure things
-- a bit. Can't just catch everything - in particular EOFs from the socket
-- loops get thrown to this thread and we musn't just ignore them.
handleIrc :: MonadError IRCError m => (IRCError -> m ()) -> m () -> m ()
handleIrc handler m = catchError m handler

-- Like handleIrc, but with arguments reversed
catchIrc :: MonadError IRCError m => m () -> (IRCError -> m ()) -> m ()
catchIrc = flip handleIrc