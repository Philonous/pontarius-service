{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module State where

import           Control.Concurrent.STM
import           Control.Lens
import           Control.Monad.Trans.Either
import qualified Network.Xmpp as Xmpp

import           Base
import           Control.Monad.Trans
import           Gpg
import           Persist
import           Types

-- | Update the current state when an identifiable condition is found.
updateState :: MonadIO m => PSM m ()
updateState = do
    -- | If a condition that triggers a state transition is found we immediately
    -- return it with left.
    eNewState <- runEitherT $ do
        liftIO . logDebug . show =<< lift getCredentials
        getCredentials `orIs` (Just CredentialsUnset)
        lift getSigningKey  >>= \case
            Nothing -> liftIO getIdentities >>= \case
                [] -> do -- createGpgKey
                         is Nothing
                _ -> is (Just IdentitiesAvailable)
            Just key -> do
                ids <- liftIO getIdentities
                if privIdentKeyID key `elem` ids
                   then return ()
                   else is (Just IdentityNotFound)
        mbCon <- liftIO . atomically . readTVar =<< view xmppCon
        case mbCon of
            XmppNoConnection -> is (Just Disabled)
            XmppConnecting _ -> is (Just Authenticating)
            XmppConnected con _ _ -> do
                sstate <- liftIO . atomically $ Xmpp.streamState con
                case sstate of
                    Xmpp.Plain -> is (Just Authenticating)
                    Xmpp.Secured -> is Nothing
                    Xmpp.Closed -> is (Just Authenticating)
                    Xmpp.Finished -> is Nothing
    case eNewState of
        -- | Writing to the TVar will automatically trigger a signal if necessary
        Left (Just newState) -> do
            setState newState
        -- | No state-changing condition was found, we keep the old state
        _ -> return ()
  where
    orIs m st = lift m >>= \case
        Just _ -> return ()
        Nothing -> left st
    is = left
