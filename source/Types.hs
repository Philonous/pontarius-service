{-# LANGUAGE FunctionalDependencies #-}
{-# OPTIONS_GHC  -fno-warn-incomplete-patterns #-}

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}

module Types
  ( module PontariusService.Types
  , module Types
  ) where

import           Control.Concurrent
import           Control.Concurrent.STM
import qualified Control.Event.Handler as RB
import qualified Control.Exception as Ex
import           Control.Lens
import           Control.Monad.Catch
import           Control.Monad.Reader
import           DBus
import           DBus.Signal
import           DBus.Types
import           Data.Set (Set)
import           Data.Text (Text)
import           Data.UUID (UUID)
import qualified Data.UUID as UUID
import           Database.Persist.Sqlite
import qualified Network.Xmpp as Xmpp
import qualified Network.Xmpp.E2E as Xmpp
import qualified Network.Xmpp.IM as Xmpp

import           PontariusService.Types

class Signaling m where
    signals :: SomeSignal -> m ()

instance Signaling (MethodHandlerT IO) where
    signals = signal'

instance (MonadTrans t, MonadReader DBusConnection (t IO)) => Signaling (t IO) where
    signals s = do
        dbc <- ask
        lift $ emitSignal' s dbc

class MonadMethodError m where
    throwMethodError :: MsgError -> m a

instance Monad m => MonadMethodError (MethodHandlerT m) where
    throwMethodError = methodError

instance MonadMethodError IO where
    throwMethodError = Ex.throwIO

data PSProperties = PSProperties{ _pspConnectionStatus :: Property (RepType Bool)}

-- | When requesting a new connection we fork a new thread that creates the
-- connection and sets it's own threadID so it can be aborted when required
data XmppState = XmppConnecting ThreadId
               | XmppConnected  Xmpp.Session Xmpp.E2EContext [ThreadId]
               | XmppNoConnection

instance Show XmppState where
    show (XmppConnecting tid) = "<Connecting, thread = " ++ show tid ++ " >"
    show XmppConnected{} = "Connected"
    show XmppNoConnection = "Disconnected"

data PSCallbacks = PSCallbacks { _onStateChange :: !(XmppState -> PSM IO ())
                               }

type Callback a = a -> IO ()
newtype FrpHandler a = FrpHandler (Callback a)

data FrpCallbacks m = FrpCallbacks
                      { frpCallbacksRosterUpdate :: m Xmpp.RosterUpdate
                      }

data PSState = PSState { _db                    :: !ConnectionPool
                       , _xmppCon               :: !(TVar XmppState)
                       , _props                 :: !(TMVar PSProperties)
                       , _state                 :: !(TVar PontariusState)
                       , _accountState          :: !(TVar AccountState)
                       , _gpgCreateKeySempahore :: !(TMVar ThreadId)
                       , _dBusConnection        :: !(TMVar DBusConnection)
                       , _subscriptionRequests  :: !(TVar (Set Xmpp.Jid))
                       , _callbacks             :: !PSCallbacks
                       , _frpCallbacks          :: !(FrpCallbacks FrpHandler)
                       }

newtype PSM m a = PSM {unPSM :: ReaderT PSState m a}
                deriving (Monad, Applicative, Functor, MonadIO, MonadTrans
                         , MonadThrow, MonadCatch
                         )

deriving instance Monad m => MonadReader PSState (PSM m)

instance Representable (Maybe UUID) where
  type RepType (Maybe UUID) = RepType Text
  toRep Nothing = toRep ("" :: Text)
  toRep (Just x) = toRep x
  fromRep v = case fromRep v of
               Nothing -> Nothing
               Just "" -> Just Nothing
               Just txt -> Just <$> UUID.fromText txt

makePrisms ''FrpHandler

makeLensesWith camelCaseFields ''FrpCallbacks
makeLensesWith camelCaseFields ''PSProperties
makeLenses                     ''PSCallbacks
makeLenses                     ''PSState
