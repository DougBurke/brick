{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
module Main where

#if !(MIN_VERSION_base(4,11,0))
import Data.Monoid
#endif
import qualified Graphics.Vty as V

import qualified Brick.Main as M
import qualified Brick.Widgets.List as L
import Brick.Types
  ( Widget
  , BrickEvent(..)
  )
import Brick.Widgets.Center
  ( center
  )
import Brick.Widgets.Border
  ( border
  )
import Brick.Widgets.Core
  ( hLimit
  , vLimit
  )
import Brick.Widgets.FileBrowser as FB
import qualified Brick.AttrMap as A
import Brick.Util (on, bg)
import qualified Brick.Types as T

data Name = FileBrowser1
          deriving (Eq, Show, Ord)

drawUI :: FileBrowser Name -> [Widget Name]
drawUI b = [ui]
    where
        ui = center $
             vLimit 15 $
             hLimit 50 $
             border $
             FB.renderFileBrowser True b

appEvent :: FB.FileBrowser Name -> BrickEvent Name e -> T.EventM Name (T.Next (FB.FileBrowser Name))
appEvent b (VtyEvent ev) =
    case ev of
        V.EvKey V.KEsc [] -> M.halt b
        _ -> M.continue =<< FB.handleFileBrowserEvent ev b
appEvent b _ = M.continue b

theMap :: A.AttrMap
theMap = A.attrMap V.defAttr
    [ (L.listSelectedFocusedAttr, V.black `on` V.yellow)
    ]

theApp :: M.App (FileBrowser Name) e Name
theApp =
    M.App { M.appDraw = drawUI
          , M.appChooseCursor = M.showFirstCursor
          , M.appHandleEvent = appEvent
          , M.appStartEvent = return
          , M.appAttrMap = const theMap
          }

main :: IO ()
main = do
    b <- M.defaultMain theApp =<< FB.newFileBrowser FileBrowser1 Nothing
    putStrLn $ "Selected entry: " <> show (FB.fileBrowserSelection b)