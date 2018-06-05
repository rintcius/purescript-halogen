module Halogen.Query.EventSource where

import Prelude

import Control.Coroutine as CR
import Control.Monad.Free.Trans as FT
import Control.Monad.Trans.Class (lift)
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Maybe (Maybe, maybe)
import Data.Newtype (class Newtype)
import Data.Profunctor (dimap)
import Effect (Effect)
import Effect.Aff (Aff, attempt, launchAff_)
import Effect.Aff.AVar as AV
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Effect.Exception as Exn
import Web.Event.Event as E
import Web.Event.EventTarget as ET

-- | An event source definition - an effect in `m` that when run returns a
-- | producer coroutine that emits queries of type `f`, and runs in the effect
-- | monad `m`.
-- |
-- | It's generally unnecessary to build values of this type directly with this
-- | constructor, the `affEventSource` and `effEventSource` cover the most
-- | event source constructions.
newtype EventSource m f =
  EventSource (m { producer :: CR.Producer (f Unit) m Unit, finalizer :: Finalizer m })

derive instance newtypeEventSource :: Newtype (EventSource m f) _

-- | Constructs an event source from a setup function that operates in `Aff`.
-- |
-- | - The `Emitter` that the passed function receives is used to `emit` queries
-- |   that will be received by the current component, or can be `close`d to
-- |   shut down the event source and remove the subscription.
-- | - The `Finalizer` that the passed function produces is there to allow for
-- |   some clean-up action to be taken when the event source is unsubscribed
-- |   from. This also runs if the `Emitter` is `close`d. `mempty` can be used
-- |   here if there is no clean-up to perform.
affEventSource
  :: forall m f
   . MonadAff m
  => (Emitter Aff f -> Aff (Finalizer Aff))
  -> EventSource m f
affEventSource recv = EventSource $ liftAff do
  inputVar <- AV.empty
  finalizeVar <- AV.empty
  let
    producer = do
      lift $ liftAff $ flip AV.put finalizeVar =<< recv (Emitter (flip AV.put inputVar))
      CR.producer $ liftAff $ AV.take inputVar
    finalizer = Finalizer do
      liftAff (attempt (AV.take finalizeVar)) >>= case _ of
        Left _ -> pure unit
        Right z -> liftAff do
          AV.kill (Exn.error "finalized") finalizeVar
          finalize z
  pure { producer, finalizer }

-- | Constructs an event source from a setup function that operates in `Eff`.
-- |
-- | - The `Emitter` that the passed function receives is used to `emit` queries
-- |   that will be received by the current component, or can be `close`d to
-- |   shut down the event source and remove the subscription.
-- | - The `Finalizer` that the passed function produces is there to allow for
-- |   some clean-up action to be taken when the event source is unsubscribed
-- |   from. This also runs if the `Emitter` is `close`d. `mempty` can be used
-- |   here if there is no clean-up to perform.
effEventSource
  :: forall m f
   . MonadAff m
  => (Emitter Effect f -> Effect (Finalizer Effect))
  -> EventSource m f
effEventSource =
  affEventSource <<<
    dimap
      (hoistEmitter launchAff_)
      (liftEffect <<< map (hoistFinalizer liftEffect))

-- | Constructs an event source from an event in the DOM. Accepts a function
-- | that maps event values to a `Maybe`-wrapped query, allowing it to filter
-- | events if necessary.
eventListenerEventSource
  :: forall m f
   . MonadAff m
  => E.EventType
  -> ET.EventTarget
  -> (E.Event -> Maybe (f Unit))
  -> EventSource m f
eventListenerEventSource eventType target f = effEventSource \emitter -> do
  listener <- ET.eventListener (maybe (pure unit) (emit emitter <<< pure) <<< f)
  ET.addEventListener eventType listener false target
  pure $ Finalizer (ET.removeEventListener eventType listener false target)

-- | Changes the query component of an event source.
interpret :: forall m f g. Functor m => (f ~> g) -> EventSource m f -> EventSource m g
interpret f (EventSource es) =
  EventSource $
    map
      (\e -> { producer: FT.interpret (lmap f) e.producer, finalizer: e.finalizer })
      es

-- | Changes the effect monad component of an event source.
hoist :: forall m n f. Functor n => (m ~> n) -> EventSource m f -> EventSource n f
hoist nat (EventSource es) =
  EventSource $
    map
      (\e -> { producer: FT.hoistFreeT nat e.producer, finalizer: hoistFinalizer nat e.finalizer })
      (nat es)

-- | Values of this type are created internally by `affEventSource` and
-- | `effEventSource`, and then passed into the user-provided setup function.
-- |
-- | This type is just a wrapper around a callback, used to simplify the type
-- | signatures for setting up event sources.
newtype Emitter m f = Emitter (Either (f Unit) Unit -> m Unit)

-- | Emits an "action style" query via the emitter. Accepts a partially applied
-- | query constructor to save having to use `H.action` or applying `unit` when
-- | constructing the query, for example:
-- |
-- | ``` purescript
-- | data Query a = Notify String a
-- |
-- | myEventSource = EventSource.affEventSource \emitter -> do
-- |   Aff.delay (Milliseconds 1000.0)
-- |   EventSource.emit emitter (Notify "hello")
-- |   pure mempty
-- | ```
emit :: forall m f. Emitter m f -> (Unit -> f Unit) -> m Unit
emit (Emitter f) q = f (Left (q unit))

-- | Closes the emitter, shutting down the event source. This allows an event
-- | source to stop itself internally, rather than requiring external shutdown
-- | by unsubscribing from it.
-- |
-- | The event source will automatically be unsubscribed from when this is
-- | called, and the finalizer returned during event source setup will be
-- | executed.
-- |
-- | Any further calls to `emit` after `close` will be ignored.
close :: forall m a. Emitter m a -> m Unit
close (Emitter f) = f (Right unit)

-- | Changes the effect monad for an emitter.
hoistEmitter :: forall m n f. (m Unit -> n Unit) -> Emitter m f -> Emitter n f
hoistEmitter nat (Emitter f) = Emitter (nat <<< f)

-- | When setting up an event source, values of this type should be returned to
-- | describe any clean-up operations required. This is just a newtype around
-- | an effectful operation, but helps with type signature comprehension.
-- |
-- | There is a `Monoid` instance provided for finalizers, so `mempty` can be
-- | used in cases where there are no relevant clean-up actions to take.
newtype Finalizer m = Finalizer (m Unit)

instance semigroupFinalizer :: Apply m => Semigroup (Finalizer m) where
  append (Finalizer a) (Finalizer b) = Finalizer (a *> b)

instance monoidFinalizer :: Applicative m => Monoid (Finalizer m) where
  mempty = Finalizer (pure unit)

-- | Runs a finalizer.
finalize :: forall m. Finalizer m -> m Unit
finalize (Finalizer a) = a

-- | Changes the effect monad for a finalizer.
hoistFinalizer :: forall m n. (m ~> n) -> Finalizer m -> Finalizer n
hoistFinalizer nat (Finalizer a) = Finalizer (nat a)
