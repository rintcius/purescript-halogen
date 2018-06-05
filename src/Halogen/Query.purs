-- | Functions and types used to describe the `HalogenF` algebra used in a
-- | component's `eval` function.
module Halogen.Query
  ( Action
  , action
  , Request
  , request
  , query
  , query'
  , queryAll
  , queryAll'
  , getHTMLElementRef
  , module Exports
  , module Halogen.Query.EventSource
  , module Halogen.Query.InputF
  , module Halogen.Query.HalogenM
  ) where

import Prelude

import Control.Monad.State.Class (get, gets, modify, modify_, put) as Exports
import Control.Monad.Trans.Class (lift) as Exports
import Control.Parallel (parTraverse)
import Data.List as L
import Data.Map as M
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (liftAff) as Exports
import Effect.Class (liftEffect) as Exports
import Halogen.Component.ChildPath (ChildPath, injSlot, prjSlot, injQuery, cpI)
import Halogen.Query.EventSource (EventSource, affEventSource, effEventSource, eventListenerEventSource)
import Halogen.Query.HalogenM (HalogenM(..), HalogenF(..), SubscriptionId(..), fork, getRef, getSlots, checkSlot, mkQuery, subscribe, unsubscribe, raise)
import Halogen.Query.InputF (RefLabel(..))
import Web.HTML.HTMLElement (HTMLElement)
import Web.HTML.HTMLElement as HTMLElement

-- | Type synonym for an "action" - An action only causes effects and has no
-- | result value.
-- |
-- | In a query algebra, an action is any constructor that carries the algebra's
-- | type variable as a value. For example:
-- |
-- | ``` purescript
-- | data Query a
-- |   = SomeAction a
-- |   | SomeOtherAction String a
-- |   | NotAnAction (Boolean -> a)
-- | ```
-- |
-- | Both `SomeAction` and `SomeOtherAction` have `a` as a value so they are
-- | considered actions, whereas `NotAnAction` has `a` as the result of a
-- | function so is considered to be a "request" ([see below](#Request)).
type Action f = Unit -> f Unit

-- | Takes a data constructor of query algebra `f` and creates an action.
-- |
-- | For example:
-- |
-- | ```purescript
-- | data Query a = Tick a
-- |
-- | sendTick :: forall o. HalogenIO Query o Aff -> Aff Unit
-- | sendTick app = app.query (action Tick)
-- | ```
action :: forall f. Action f -> f Unit
action act = act unit

-- | Type synonym for an "request" - a request can cause effects as well as
-- | fetching some information from a component.
-- |
-- | In a query algebra, an action is any constructor that carries the algebra's
-- | type variable as the return value of a function. For example:
-- |
-- | ``` purescript
-- | data Query a = SomeRequest (Boolean -> a)
-- | ```
type Request f a = (a -> a) -> f a

-- | Takes a data constructor of query algebra `f` and creates a request.
-- |
-- | For example:
-- |
-- | ```purescript
-- | data Query a = GetTickCount (Int -> a)
-- |
-- | getTickCount :: forall o. HalogenIO Query o Aff -> Aff Int
-- | getTickCount app = app.query (request GetTickCount)
-- | ```
request :: forall f a. Request f a -> f a
request req = req identity

-- | Sends a query to a child of a component at the specified slot.
query
  :: forall s f g p o m a
   . Eq p
  => p
  -> g a
  -> HalogenM s f g p o m (Maybe a)
query p q = checkSlot p >>= if _ then Just <$> mkQuery p q else pure Nothing

-- | Sends a query to a child of a component at the specified slot, using a
-- | `ChildPath` to discriminate the type of child component to query.
query'
  :: forall s f g g' m p p' o a
   . Eq p'
  => ChildPath g g' p p'
  -> p
  -> g a
  -> HalogenM s f g' p' o m (Maybe a)
query' path p q = query (injSlot path p) (injQuery path q)

-- | Sends a query to all children of a component.
queryAll
  :: forall s f g p o m a
   . Ord p
  => g a
  -> HalogenM s f g p o m (M.Map p a)
queryAll = queryAll' cpI

-- | Sends a query to all children of a specific type within a component, using
-- | a `ChildPath` to discriminate the type of child component to query.
queryAll'
  :: forall s f g g' p p' o m a
   . Ord p
  => Eq p'
  => ChildPath g g' p p'
  -> g a
  -> HalogenM s f g' p' o m (M.Map p a)
queryAll' path q = do
  slots <- L.mapMaybe (prjSlot path) <$> getSlots
  M.fromFoldable <$>
    parTraverse
      (\p -> map (Tuple p) (mkQuery (injSlot path p) (injQuery path q)))
      slots

getHTMLElementRef :: forall s f g p o m. RefLabel -> HalogenM s f g p o m (Maybe HTMLElement)
getHTMLElementRef = map (HTMLElement.fromElement =<< _) <<< getRef
