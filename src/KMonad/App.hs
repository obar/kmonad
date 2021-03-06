{-# OPTIONS_GHC -Wno-orphans #-}
{-|
Module      : KMonad.App
Description : The central app-loop of KMonad
Copyright   : (c) David Janssen, 2019
License     : MIT
Maintainer  : janssen.dhj@gmail.com
Stability   : experimental
Portability : portable

-}
module KMonad.App
  ( AppCfg(..)
  , HasAppCfg(..)
  , startApp
  )
where

import KMonad.Prelude

import KMonad.Action
import KMonad.Button
import KMonad.Keyboard
import KMonad.Keyboard.IO
import KMonad.Util
import KMonad.App.BEnv

import qualified KMonad.App.Dispatch as Dp
import qualified KMonad.App.Hooks    as Hs
import qualified KMonad.App.Sluice   as Sl
import qualified KMonad.App.Keymap   as Km

--------------------------------------------------------------------------------
-- $appcfg
--
-- The 'AppCfg' and 'AppEnv' records store the configuration and runtime
-- environment of KMonad's app-loop respectively. This contains nearly all of
-- the components required to run KMonad.
--
-- Note that the 'AppEnv' is still not sufficient to satisfy 'MonadK', since
-- there are times where we are not processing a button push. I.e. 'MonadK' is a
-- series of operations that allow us to specify how to deal with the current
-- button-push, but it required us to have actually registered a push (or
-- release) of some button. 'AppEnv' exists before any buttons have been pushed,
-- and therefore contains no information about 'the current button push' (nor
-- could it). Later in this module we specify KEnv as a combination of AppEnv
-- and a BEnv. It is that environment that we use to satisfy 'MonadK'.

-- | Record of all the configuration options required to run KMonad's core App
-- loop.
data AppCfg = AppCfg
  { _keySinkDev   :: Acquire KeySink   -- ^ How to open a 'KeySink'
  , _keySourceDev :: Acquire KeySource -- ^ How to open a 'KeySource'
  , _keymapCfg    :: LMap Button       -- ^ The map defining the 'Button' layout
  , _firstLayer   :: LayerTag          -- ^ Active layer when KMonad starts
  , _fallThrough  :: Bool              -- ^ Whether uncaught events should be emitted or not
  }
makeClassy ''AppCfg


-- | Environment of a running KMonad app-loop
data AppEnv = AppEnv
  { -- Stored copy of cfg
    _keAppCfg   :: AppCfg
   
    -- General IO
  , _keLogFunc  :: LogFunc
  , _keySink    :: KeySink
  , _keySource  :: KeySource

    -- Pull chain
  , _dispatch   :: Dp.Dispatch
  , _inHooks    :: Hs.Hooks
  , _sluice     :: Sl.Sluice

    -- Other components
  , _keymap     :: Km.Keymap
  , _outHooks   :: Hs.Hooks
  , _outVar     :: TMVar KeyEvent
  }
makeClassy ''AppEnv

instance HasLogFunc AppEnv where logFuncL = keLogFunc
instance HasAppCfg  AppEnv where appCfg   = keAppCfg


--------------------------------------------------------------------------------
-- $init

-- | Initialize all the components of the KMonad app-loop
--
-- NOTE: This is written in 'ContT' over our normal RIO monad. This is just to
-- to simplify a bunch of nesting of calls. At no point do we make use of
-- 'callCC' or other 'ContT' functionality.
--
initAppEnv :: HasLogFunc e => AppCfg -> ContT r (RIO e) AppEnv
initAppEnv cfg = do
  -- Get a reference to the logging function
  lgf <- view logFuncL

  -- Acquire the keysource and keysink
  snk <- using $ cfg^.keySinkDev
  src <- using $ cfg^.keySourceDev

  -- Initialize the pull-chain components
  dsp <- Dp.mkDispatch $ awaitKey src
  ihk <- Hs.mkHooks    $ Dp.pull  dsp
  slc <- Sl.mkSluice   $ Hs.pull  ihk

  -- Initialize the button environments in the keymap
  phl <- Km.mkKeymap (cfg^.firstLayer) (cfg^.keymapCfg)

  -- Initialize output components
  otv <- lift . atomically $ newEmptyTMVar
  ohk <- Hs.mkHooks . atomically . takeTMVar $ otv

  -- Setup thread to read from outHooks and emit to keysink
  launch_ "emitter_proc" $ do
    e <- atomically . takeTMVar $ otv
    emitKey snk e
  -- emit e = view keySink >>= flip emitKey e
  pure $ AppEnv
    { _keAppCfg  = cfg
    , _keLogFunc = lgf
    , _keySink   = snk
    , _keySource = src

    , _dispatch  = dsp
    , _inHooks   = ihk
    , _sluice    = slc

    , _keymap    = phl
    , _outHooks  = ohk
    , _outVar    = otv
    }


--------------------------------------------------------------------------------
-- $loop
--
-- The central app-loop of KMonad.

-- | Trigger the button-action press currently registered to 'Keycode'
pressKey :: (HasAppEnv e, HasLogFunc e, HasAppCfg e) => Keycode -> RIO e ()
pressKey c =
  view keymap >>= flip Km.lookupKey c >>= \case

    -- If the keycode does not occur in our keymap
    Nothing -> do
      ft <- view fallThrough
      if ft
        then do
          emit $ mkPress c
          await (isReleaseOf c) $ \_ -> do
            emit $ mkRelease c
            pure Catch
        else pure ()

    -- If the keycode does occur in our keymap
    Just b  -> runBEnv b Press >>= \case
      Nothing -> pure ()  -- If the previous action on this key was *not* a release
      Just a  -> do
        -- Execute the press and register the release
        app <- view appEnv
        runRIO (KEnv app b) $ do
          runAction a
          awaitMy Release $ do
            runBEnv b Release >>= maybe (pure ()) runAction
            pure Catch

-- | Perform 1 step of KMonad's app loop
--
-- We forever:
-- 1. Pull from the pull-chain until an unhandled event reaches us.
-- 2. If that event is a 'Press' we use our keymap to trigger an action.
loop :: RIO AppEnv ()
loop = forever $ view sluice >>= Sl.pull >>= \case
  e | e^.switch == Press -> pressKey $ e^.keycode
  _                      -> pure ()

-- | Run KMonad using the provided configuration
startApp :: HasLogFunc e => AppCfg -> RIO e ()
startApp c = runContT (initAppEnv c) (flip runRIO loop)

instance (HasAppEnv e, HasLogFunc e) => MonadKIO (RIO e) where
  -- Emitting with the keysink
  emit e = view outVar >>= atomically . flip putTMVar e
  -- emit e = view keySink >>= flip emitKey e

  -- Pausing is a simple IO action
  pause = threadDelay . (*1000) . fromIntegral

  -- Holding and rerunning through the sluice and dispatch
  hold b = do
    sl <- view sluice
    di <- view dispatch
    if b then Sl.block sl else Sl.unblock sl >>= Dp.rerun di

  -- Hooking is performed with the hooks component
  register l h = do
    hs <- case l of
      InputHook  -> view inHooks
      OutputHook -> view outHooks
    Hs.register hs h

  -- Layer-ops are sent to the 'Keymap'
  layerOp o = view keymap >>= \hl -> Km.layerOp hl o

  -- Injecting by adding to Dispatch's rerun buffer
  inject e = do
    di <- view dispatch
    logDebug $ "Injecting event: " <> display e
    Dp.rerun di [e]


--------------------------------------------------------------------------------
-- $kenv
--

-- | The complete environment capable of satisfying 'MonadK'
data KEnv = KEnv
  { _kAppEnv :: AppEnv -- ^ The app environment containing all the components
  , _kBEnv   :: BEnv   -- ^ The environment describing the currently active button
  }
makeClassy ''KEnv

instance HasAppEnv  KEnv where appEnv       = kAppEnv
instance HasBEnv    KEnv where bEnv         = kBEnv
instance HasLogFunc KEnv where logFuncL     = kAppEnv.logFuncL

-- | Hook up all the components to the different 'MonadK' functionalities
instance MonadK (RIO KEnv) where
  -- Binding is found in the stored 'BEnv'
  myBinding = view (bEnv.binding)
