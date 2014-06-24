{-# LANGUAGE RankNTypes #-}
module Lambdabot.Monad where

import Control.Monad.Reader
import Data.IORef

newtype LB a = LB { runLB :: ReaderT (IRCRState,IORef IRCRWState) IO a }
instance Monad LB

data IRCRState
data IRCRWState
