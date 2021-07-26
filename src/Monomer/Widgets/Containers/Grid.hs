{-|
Module      : Monomer.Widgets.Containers.Grid
Copyright   : (c) 2018 Francisco Vallarino
License     : BSD-3-Clause (see the LICENSE file)
Maintainer  : fjvallarino@gmail.com
Stability   : experimental
Portability : non-portable

Layout container which distributes size equally along the main axis. For hgrid
it requests max width * elements as its width, and the max height as its height.
The reverse happens for vgrid.

Configs:

- sizeReqUpdater: allows modifying the 'SizeReq' generated by the grid.
-}
{-# LANGUAGE FlexibleContexts #-}

module Monomer.Widgets.Containers.Grid (
  hgrid,
  hgrid_,
  vgrid,
  vgrid_
) where

import Control.Applicative ((<|>))
import Control.Lens ((&), (^.), (.~))
import Data.Default
import Data.List (foldl')
import Data.Maybe
import Data.Sequence (Seq(..), (|>))

import qualified Data.Sequence as Seq

import Monomer.Widgets.Container

import qualified Monomer.Lens as L

newtype GridCfg = GridCfg {
  _grcSizeReqUpdater :: Maybe SizeReqUpdater
}

instance Default GridCfg where
  def = GridCfg {
    _grcSizeReqUpdater = Nothing
  }

instance Semigroup GridCfg where
  (<>) s1 s2 = GridCfg {
    _grcSizeReqUpdater = _grcSizeReqUpdater s2 <|> _grcSizeReqUpdater s1
  }

instance Monoid GridCfg where
  mempty = def

instance CmbSizeReqUpdater GridCfg where
  sizeReqUpdater updater = def {
    _grcSizeReqUpdater = Just updater
  }

-- | Creates a grid of items with the same width.
hgrid :: Traversable t => t (WidgetNode s e) -> WidgetNode s e
hgrid children = hgrid_ def children

-- | Creates a grid of items with the same width. Accepts config.
hgrid_ :: Traversable t => [GridCfg] -> t (WidgetNode s e) -> WidgetNode s e
hgrid_ configs children = newNode where
  config = mconcat configs
  newNode = defaultWidgetNode "hgrid" (makeFixedGrid True config)
    & L.children .~ foldl' (|>) Empty children

-- | Creates a grid of items with the same height.
vgrid :: Traversable t => t (WidgetNode s e) -> WidgetNode s e
vgrid children = vgrid_ def children

-- | Creates a grid of items with the same height. Accepts config.
vgrid_ :: Traversable t => [GridCfg] -> t (WidgetNode s e) -> WidgetNode s e
vgrid_ configs children = newNode where
  config = mconcat configs
  newNode = defaultWidgetNode "vgrid" (makeFixedGrid False config)
    & L.children .~ foldl' (|>) Empty children

makeFixedGrid :: Bool -> GridCfg -> Widget s e
makeFixedGrid isHorizontal config = widget where
  widget = createContainer () def {
    containerLayoutDirection = getLayoutDirection isHorizontal,
    containerGetSizeReq = getSizeReq,
    containerResize = resize
  }

  isVertical = not isHorizontal

  getSizeReq wenv node children = newSizeReq where
    updateSizeReq = fromMaybe id (_grcSizeReqUpdater config)
    vchildren = Seq.filter (_wniVisible . _wnInfo) children
    newSizeReqW = getDimSizeReq isHorizontal (_wniSizeReqW . _wnInfo) vchildren
    newSizeReqH = getDimSizeReq isVertical (_wniSizeReqH . _wnInfo) vchildren
    newSizeReq = updateSizeReq (newSizeReqW, newSizeReqH)

  getDimSizeReq mainAxis accesor vchildren
    | Seq.null vreqs = fixedSize 0
    | mainAxis = foldl1 sizeReqMergeSum (Seq.replicate nreqs maxSize)
    | otherwise = maxSize
    where
      vreqs = accesor <$> vchildren
      nreqs = Seq.length vreqs
      maxSize = foldl1 sizeReqMergeMax vreqs

  resize wenv node viewport children = resized where
    style = currentStyle wenv node
    contentArea = fromMaybe def (removeOuterBounds style viewport)
    Rect l t w h = contentArea
    vchildren = Seq.filter (_wniVisible . _wnInfo) children

    cols = if isHorizontal then length vchildren else 1
    rows = if isHorizontal then 1 else length vchildren

    cw = if cols > 0 then w / fromIntegral cols else 0
    ch = if rows > 0 then h / fromIntegral rows else 0

    cx i
      | rows > 0 = l + fromIntegral (i `div` rows) * cw
      | otherwise = 0
    cy i
      | cols > 0 = t + fromIntegral (i `div` cols) * ch
      | otherwise = 0

    foldHelper (currAreas, index) child = (newAreas, newIndex) where
      (newIndex, newViewport)
        | child ^. L.info . L.visible = (index + 1, calcViewport index)
        | otherwise = (index, def)
      newArea = newViewport
      newAreas = currAreas |> newArea
    calcViewport i = Rect (cx i) (cy i) cw ch

    assignedAreas = fst $ foldl' foldHelper (Seq.empty, 0) children
    resized = (resultNode node, assignedAreas)
