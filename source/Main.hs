{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

import           Control.Applicative
import           Control.Concurrent.STM
import qualified Control.Event.Handler as RB
import qualified Reactive.Banana as RB
import           Control.Monad.Logger hiding (logDebug)
import           Control.Monad.Reader
import           Control.Monad.Trans.Resource
import           DBus
import           DBus.Introspect (introspect)
import           DBus.Property
import           Data.Maybe (isJust)
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as Set
import qualified Data.Text.IO as Text
import           Database.Persist.Sqlite
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.Log.Formatter
import           System.Log.Handler hiding (setLevel)
import           System.Log.Handler.Simple
import           System.Log.Logger

import           Base
import           DBusInterface
import           Persist
import           State
import           Transactions
import           Types
import           Xmpp

logDir = "/logs"

mkLogger loggerNames filename = do
    hndlr <- fileHandler (logDir </> filename ++ ".log") DEBUG
    let fmt = simpleLogFormatter "$time;$prio;$msg"
        hnd = setFormatter hndlr fmt
    forM_ loggerNames $ \loggerName ->
        updateGlobalLogger loggerName $ setLevel DEBUG . setHandlers [hnd]

globalLogger :: IO ()
globalLogger = do
    hnd' <- fileHandler (logDir </> "service.log") DEBUG
    let fmt = simpleLogFormatter "$time;$loggername;$prio;$msg"
        hnd = setFormatter hnd' fmt
    updateGlobalLogger rootLoggerName $ addHandler hnd . removeHandler


makeCallbacks :: IO (FrpCallbacks RB.AddHandler, FrpCallbacks FrpHandler)
makeCallbacks = do
    (rosterUpdateAH, rosterUpdateCallback) <- RB.newAddHandler
    let handlers = FrpCallbacks  {frpCallbacksRosterUpdate = rosterUpdateAH }
        callbacks = FrpCallbacks
                     {frpCallbacksRosterUpdate = FrpHandler rosterUpdateCallback
                     }
    return (handlers, callbacks)

main :: IO ()
main = runNoLoggingT . withSqlitePool "config.db3" 3 $ \pool -> liftIO $ do
    args <- getArgs
    let writeInterface = case args of
                          ["--write-interface", filename] -> Just filename
                          _ -> Nothing
    unless (isJust writeInterface) $ do
      mapM_ (\l -> updateGlobalLogger l $ setLevel DEBUG) $
          [ "Pontarius.Xmpp", "DBus" ]
      globalLogger
      mkLogger ["Pontarius.Xmpp"] "xmpp"
      logDebug "migrating"
    runResourceT $ flip runSqlPool pool $ runMigrationSilent migrateAll
    logDebug "setting up state"
    xmppConRef <- newTVarIO XmppNoConnection
    propertiesRef <- newEmptyTMVarIO
    pState <- newTVarIO CredentialsUnset
    accState <- newTVarIO AccountDisabled
    sem <- newEmptyTMVarIO
    conRef <- newEmptyTMVarIO
    subReqsRef <- newTVarIO Set.empty
    (addHandlers, handlers) <- makeCallbacks
    let psState = PSState { _db = pool
                          , _xmppCon = xmppConRef
                          , _props = propertiesRef
                          , _state = pState
                          , _accountState = accState
                          , _gpgCreateKeySempahore = sem
                          , _dBusConnection = conRef
                          , _subscriptionRequests = subReqsRef
                          , _callbacks = PSCallbacks
                                            { _onStateChange = onXmppStateChange }
                          , _frpCallbacks = handlers
                          }
        getStatus = readTVar pState
        getEnabled = (== AccountEnabled) <$> readTVar accState
        statusProp = mkProperty pontariusObjectPath pontariusInterface
                         "Status"
                         (Just (lift $ atomically getStatus))
                         Nothing
                         PECSTrue
        enabledProp = mkProperty pontariusObjectPath pontariusInterface
                         "AccountEnabled"
                         (Just (lift . atomically $ getEnabled))
                         (Just $ \e -> do
                           newState <- case e of
                                True -> (runPSM psState $ enableAccount)
                                          >> return AccountEnabled

                                False -> runPSM psState $ disableAccount
                                          >> return AccountDisabled
                           liftIO . atomically $ writeTVar accState newState
                           return True
                         )
                         PECSTrue
        usernameProp = mkProperty  pontariusObjectPath pontariusInterface
                         "Username"
                         (Just (getCredentialsM psState))
                         Nothing
                         PECSTrue
        peersProp = mkProperty  pontariusObjectPath pontariusInterface
                         "Peers"
                         (Just . lift . atomically $ getPeersSTM psState)
                         Nothing
                         PECSTrue
        availableEntitiesProp = mkProperty pontariusObjectPath pontariusInterface
                         "AvailableEntities"
                         (Just $ runPSM psState getAvailableXmppPeers)
                         Nothing
                         PECSTrue
        ro = rootObject psState <> property statusProp
                                <> property enabledProp
                                <> property usernameProp
                                <> property peersProp
                                <> property availableEntitiesProp
    case writeInterface of
     Just filename -> do
         Text.writeFile filename $ introspect "/" False ro
         exitSuccess
     Nothing -> return ()
    logDebug "connecting to dbus"
    con <- makeServer DBus.Session ro
    logDebug "setting dbus session"
    atomically $ putTMVar conRef con
    logDebug "requesting dbus name"
    requestName "org.pontarius" def con >>= liftIO . \case
        PrimaryOwner -> return ()
        DBus.InQueue -> do
            logDebug "dbus name is already taken"
            exitSuccess
        DBus.Exists -> do
            logDebug "dbus name is already taken"
            exitSuccess
        DBus.AlreadyOwner -> do
            logDebug "dbus server reports \"already owner\"?!?"
    logDebug "setting up properties"
    manageStmProperty statusProp getStatus con
    manageStmProperty enabledProp  getEnabled con
    manageStmProperty peersProp (getPeersSTM psState) con
    logDebug "updating state"
    runPSM psState updateState
    logDebug "done updating state"
    waitFor con
