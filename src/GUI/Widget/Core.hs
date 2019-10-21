{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RecordWildCards #-}

module GUI.Widget.Core where

import Control.Monad
import Control.Monad.State

import Data.Default
import Data.Maybe
import Data.String

import GUI.Common.Core
import GUI.Common.Style
import GUI.Data.Tree

import qualified Data.Text as T
import qualified Data.Sequence as SQ

type Timestamp = Int
type Enabled = Bool
type Focused = Bool
type KeyCode = Int

type WidgetNode s e m = Tree (WidgetInstance s e m)

data Direction = Horizontal | Vertical deriving (Show, Eq)

data Button = LeftBtn | RightBtn deriving (Show, Eq)
data ButtonState = PressedBtn | ReleasedBtn deriving (Show, Eq)

data KeyMotion = KeyPressed | KeyReleased deriving (Show, Eq)

data SystemEvent = Click Point Button ButtonState |
                   KeyAction KeyCode KeyMotion deriving (Show, Eq)

data WidgetEventResult s e m = WidgetEventResult {
  _eventResultStop :: Bool,
  _eventResultUserEvents :: [e],
  _eventResultNewWidget :: Maybe (Widget s e m)
}

data WidgetResizeResult s e m = WidgetResizeResult {
  _resizeResultViewports :: [Rect],
  _resizeResultRenderAreas :: [Rect],
  _resizeResultWidget :: Maybe (Widget s e m)
}

widgetEventResult :: Bool -> [e] -> (Widget s e m) -> Maybe (WidgetEventResult s e m)
widgetEventResult stop userEvents newWidget = Just $ WidgetEventResult stop userEvents (Just newWidget)

newtype WidgetType = WidgetType String deriving Eq
newtype WidgetKey = WidgetKey String deriving Eq

instance IsString WidgetType where
  fromString string = WidgetType string

instance IsString WidgetKey where
  fromString string = WidgetKey string

newtype NodePath = NodePath [Int]
data NodeInfo = NodeInfo WidgetType (Maybe WidgetKey)

data GUIContext app = GUIContext {
  _appContext :: app,
  _focusRing :: [Path]
} deriving (Show, Eq)

initGUIContext :: app -> GUIContext app
initGUIContext app = GUIContext {
  _appContext = app,
  _focusRing = []
}

isFocusable :: (MonadState s m) => WidgetInstance s e m -> Bool
isFocusable (WidgetInstance { _widgetInstanceWidget = Widget{..}, ..}) = _widgetInstanceEnabled  && _widgetFocusable

data Widget s e m =
  (MonadState s m) => Widget {
    -- | Type of the widget
    _widgetType :: WidgetType,
    -- | Indicates whether the widget makes changes to the render context that needs to be restored AFTER children render
    _widgetModifiesContext :: Bool,
    -- | Indicates whether the widget can receive focus
    _widgetFocusable :: Bool,
    -- | Handles an event
    --
    -- Region assigned to the widget
    -- Event to handle
    --
    -- Returns: the list of generated events and, maybe, a new version of the widget if internal state changed
    _widgetHandleEvent :: Rect -> SystemEvent -> Maybe (WidgetEventResult s e m),
    -- | Minimum size desired by the widget
    --
    -- Style options
    -- Preferred size for each of the children widgets
    -- Renderer (mainly for text sizing functions)
    --
    -- Returns: the minimum size desired by the widget
    _widgetPreferredSize :: Renderer m -> Style -> [Size] -> m Size,
    -- | Resizes the children of this widget
    --
    -- Region assigned to the widget
    -- Style options
    -- Preferred size for each of the children widgets
    --
    -- Returns: the size assigned to each of the children
    _widgetResizeChildren :: Rect -> Style -> [Size] -> Maybe (WidgetResizeResult s e m),
    -- | Renders the widget
    --
    -- Renderer
    -- Region assigned to the widget
    -- Style options
    -- Indicates if the widget (and its children) are enabled
    -- Indicates if the widget has focus
    -- The current time in milliseconds
    --
    -- Returns: unit
    _widgetRender :: Renderer m -> Rect -> Style -> Enabled -> Focused -> Timestamp -> m ()
  }

-- | Complementary information to a Widget, forming a node in the view tree
--
-- Type variables:
-- * n: Identifier for a node
data WidgetInstance s e m =
  (MonadState s m) => WidgetInstance {
    -- | Key/Identifier of the widget. If provided, it needs to be unique in the same hierarchy level (not globally)
    _widgetInstanceKey :: Maybe WidgetKey,
    -- | The actual widget
    _widgetInstanceWidget :: Widget s e m,
    -- | Indicates if the widget is enabled for user interaction
    _widgetInstanceEnabled :: Bool,
    -- | Indicates if the widget is focused
    _widgetInstanceFocused :: Bool,
    -- | The visible area of the screen assigned to the widget
    _widgetInstanceViewport :: Rect,
    -- | The area of the screen where the widget can draw
    -- | Usually equal to _widgetInstanceViewport, but may be larger if the widget is wrapped in a scrollable container
    _widgetInstanceRenderArea :: Rect,
    -- | Style attributes of the widget instance
    _widgetInstanceStyle :: Style
  }

key :: (MonadState s m) => WidgetKey -> WidgetInstance s e m -> WidgetInstance s e m
key key wn = wn { _widgetInstanceKey = Just key }

style :: (MonadState s m) => WidgetNode s e m -> Style -> WidgetNode s e m
style (Node value children) newStyle = Node (value { _widgetInstanceStyle = newStyle }) children

children :: (MonadState s m) => WidgetNode s e m -> [WidgetNode s e m] -> WidgetNode s e m
children (Node value _) newChildren = fromList value newChildren

cascadeStyle :: (MonadState s m) => Style -> WidgetNode s e m -> WidgetNode s e m
cascadeStyle parentStyle (Node (wn@WidgetInstance{..}) children) = newNode where
  newNode = Node (wn { _widgetInstanceStyle = newStyle }) newChildren
  newStyle = _widgetInstanceStyle <> parentStyle
  newChildren = fmap (cascadeStyle newStyle) children

defaultWidgetInstance :: (MonadState s m) => Widget s e m -> WidgetInstance s e m
defaultWidgetInstance widget = WidgetInstance {
  _widgetInstanceKey = Nothing,
  _widgetInstanceWidget = widget,
  _widgetInstanceEnabled = True,
  _widgetInstanceFocused = False,
  _widgetInstanceViewport = def,
  _widgetInstanceRenderArea = def,
  _widgetInstanceStyle = mempty
}

singleWidget :: (MonadState s m) => Widget s e m -> WidgetNode s e m
singleWidget widget = singleton (defaultWidgetInstance widget)

parentWidget :: (MonadState s m) => Widget s e m -> [WidgetNode s e m] -> WidgetNode s e m
parentWidget widget = fromList (defaultWidgetInstance widget)

widgetMatches :: (MonadState s m) => WidgetInstance s e m -> WidgetInstance s e m -> Bool
widgetMatches wn1 wn2 = _widgetType (_widgetInstanceWidget wn1) == _widgetType (_widgetInstanceWidget wn2) && _widgetInstanceKey wn1 == _widgetInstanceKey wn2

mergeTrees :: (MonadState s m) => WidgetNode s e m -> WidgetNode s e m -> WidgetNode s e m
mergeTrees node1@(Node widget1 seq1) (Node widget2 seq2) = newNode where
  matches = widgetMatches widget1 widget2
  newNode = if | matches -> Node widget2 newChildren
               | otherwise -> node1
  newChildren = mergedChildren SQ.>< addedChildren
  mergedChildren = fmap mergeChild (SQ.zip seq1 seq2)
  addedChildren = SQ.drop (SQ.length seq2) seq1
  mergeChild = \(c1, c2) -> mergeTrees c1 c2

handleWidgetEvents :: (MonadState s m) => Widget s e m -> Rect -> SystemEvent -> Maybe (WidgetEventResult s e m)
handleWidgetEvents (Widget {..}) viewport systemEvent = _widgetHandleEvent viewport systemEvent

handleChildEvent :: (MonadState s m) => (a -> SQ.Seq (WidgetNode s e m) -> (a, Maybe Int)) -> a -> WidgetNode s e m -> SystemEvent -> (Bool, SQ.Seq e, Maybe (WidgetNode s e m))
handleChildEvent selectorFn selector treeNode@(Node wn@WidgetInstance{..} children) systemEvent = (stopPropagation, userEvents, newTreeNode) where
  (stopPropagation, userEvents, newTreeNode) = case spChild of
    True -> (spChild, ueChild, newNode1)
    False -> (sp, ueChild SQ.>< ue, newNode2)
  (spChild, ueChild, tnChild, tnChildIdx) = case selectorFn selector children of
    (_, Nothing) -> (False, SQ.empty, Nothing, 0)
    (newSelector, Just idx) -> (sp2, ue2, tn2, idx) where
      (sp2, ue2, tn2) = handleChildEvent selectorFn newSelector (SQ.index children idx) systemEvent
  (sp, ue, tn) = case handleWidgetEvents _widgetInstanceWidget _widgetInstanceViewport systemEvent of
    Nothing -> (False, SQ.empty, Nothing)
    Just (WidgetEventResult sp2 ue2 widget) -> (sp2, SQ.fromList ue2, if isNothing widget then Nothing else Just (Node (wn { _widgetInstanceWidget = fromJust widget }) children))
  newNode1 = case tnChild of
    Nothing -> Nothing
    Just wnChild -> Just $ Node wn (SQ.update tnChildIdx wnChild children)
  newNode2 = case (tn, tnChild) of
    (Nothing, Nothing) -> Nothing
    (Nothing, Just cn) -> newNode1
    (Just pn, Nothing) -> tn
    (Just (Node wn _), Just tnChild) -> Just $ Node wn (SQ.update tnChildIdx tnChild children)

handleEventFromPath :: (MonadState s m) => Path -> WidgetNode s e m -> SystemEvent -> (Bool, SQ.Seq e, Maybe (WidgetNode s e m))
handleEventFromPath path widgetInstance systemEvent = handleChildEvent pathSelector path widgetInstance systemEvent where
  pathSelector [] _ = ([], Nothing)
  pathSelector (p:ps) children
    | length children > p = (ps, Just p)
    | otherwise = ([], Nothing)

handleEventFromPoint :: (MonadState s m) => Point -> WidgetNode s e m -> SystemEvent -> (Bool, SQ.Seq e, Maybe (WidgetNode s e m))
handleEventFromPoint cursorPos widgetInstance systemEvent = handleChildEvent rectSelector cursorPos widgetInstance systemEvent where
  rectSelector point children = (point, SQ.lookup 0 inRectList) where
    inRectList = fmap snd $ SQ.filter inNodeRect childrenPair
    inNodeRect = \(Node (WidgetInstance {..}) _, _) -> inRect _widgetInstanceViewport point
    childrenPair = SQ.zip children (SQ.fromList [0..(length children - 1)])

handleRender :: (MonadState s m) => Renderer m -> WidgetNode s e m -> Timestamp -> m ()
handleRender renderer (Node (WidgetInstance { _widgetInstanceWidget = Widget{..}, .. }) children) ts = do
  when (_widgetModifiesContext) $ saveContext renderer

  _widgetRender renderer _widgetInstanceViewport _widgetInstanceStyle _widgetInstanceEnabled _widgetInstanceFocused ts
  mapM_ (\treeNode -> handleRender renderer treeNode ts) children

  when (_widgetModifiesContext) $ restoreContext renderer

updateWidgetInstance :: Path -> WidgetNode s e m -> (WidgetInstance s e m -> WidgetInstance s e m) -> WidgetNode s e m
updateWidgetInstance path root updateFn = updateNode path root (\(Node widgetInstance children) -> Node (updateFn widgetInstance) children)

setFocusedStatus :: Path -> Bool -> WidgetNode s e m -> WidgetNode s e m
setFocusedStatus path focused root = updateWidgetInstance path root updateFn where
  updateFn wn@(WidgetInstance {..}) = wn {
    _widgetInstanceFocused = focused
  }

resizeUI :: (MonadState s m) => Renderer m -> Rect -> WidgetNode s e m -> m (WidgetNode s e m)
resizeUI renderer assignedRect widgetInstance = do
  preferredSizes <- buildPreferredSizes renderer widgetInstance
  resizeNode renderer assignedRect assignedRect preferredSizes widgetInstance

buildPreferredSizes :: (MonadState s m) => Renderer m -> WidgetNode s e m -> m (Tree Size)
buildPreferredSizes renderer (Node (WidgetInstance {..}) children) = do
  childrenSizes <- mapM (buildPreferredSizes renderer) children
  size <- _widgetPreferredSize _widgetInstanceWidget renderer _widgetInstanceStyle (seqToList childrenSizes)

  return $ Node size childrenSizes

resizeNode :: (MonadState s m) => Renderer m -> Rect -> Rect -> Tree Size -> WidgetNode s e m -> m (WidgetNode s e m)
resizeNode renderer viewport renderArea (Node _ childrenSizes) (Node widgetInstance childrenWns) = do
    newChildren <- mapM childResize childrenPair

    return (Node updatedNode newChildren)
  where
    widget = _widgetInstanceWidget widgetInstance
    style = _widgetInstanceStyle widgetInstance
    (WidgetResizeResult viewports renderAreas newWidget) = case (_widgetResizeChildren widget) viewport style (seqToList childrenSizes) of
      Nothing -> WidgetResizeResult [] [] Nothing
      Just wrr -> wrr
    updatedNode = widgetInstance {
      _widgetInstanceViewport = viewport,
      _widgetInstanceRenderArea = renderArea,
      _widgetInstanceWidget = fromMaybe widget newWidget
    }
    childrenPair = SQ.zip4 childrenSizes childrenWns (SQ.fromList viewports) (SQ.fromList renderAreas)
    childResize = \(size, node, viewport, renderArea) -> resizeNode renderer viewport renderArea size node

