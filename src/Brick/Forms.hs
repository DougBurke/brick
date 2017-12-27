{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
-- | NOTE: This API is experimental and will probably change. Please try
-- it out! Feedback is very much appreciated!
--
-- This module provides an input form API. This API allows you to
-- construct an input interface based on a data type of your choice.
-- Each input in the form corresponds to a field in your data type. This
-- API then automatically dispatches keyboard and mouse input events to
-- each form input field, manages rendering of the form, notifies the
-- user when a form field's value is invalid, and stores valid inputs in
-- your data type when possible.
--
-- This module provides the API to create forms, populate them with some
-- basic input field types, render forms, handle form events, and create
-- custom input field types.
--
-- For an introduction to this API, see the "Input Forms" section of the
-- Brick User Guide. Also see the demonstration programs for examples of
-- forms in action.
module Brick.Forms
  ( Form
  , formFocus
  , formState
  , FormFieldState(..)
  , FormField(..)

  -- * Working with forms
  , newForm
  , handleFormEvent
  , renderForm
  , (@@=)
  , allFieldsValid
  , invalidFields

  -- * Simple form field constructors
  , editTextField
  , editShowableField
  , editPasswordField
  , radioField
  , checkboxField

  -- * Advanced form field constructors
  , editField

  -- * Attributes
  , invalidFormInputAttr
  , focusedFormInputAttr
  )
where

import Graphics.Vty
import Data.Monoid
import Data.Maybe (isJust, isNothing)

import Brick
import Brick.Focus
import Brick.Widgets.Edit

import qualified Data.Text as T
import Text.Read (readMaybe)

import Lens.Micro

-- | A form field. This represents an interactive input field in the
-- form. One or more fields may be used to manipulate a particular state
-- value.
--
-- Type variables are as follows:
--
--  * @a@ - the type of the field in your form state that this field manipulates
--  * @b@ - the form field's internal state type
--  * @e@ - your application's event type
--  * @n@ - your application's resource name type
data FormField a b e n =
    FormField { formFieldName        :: n
              -- ^ The name identifying this form field.
              , formFieldValidate    :: b -> Maybe a
              -- ^ A validation function converting this field's state
              -- into a value of your choosing. @Nothing@ indicates a
              -- validation failure.
              , formFieldRender      :: Bool -> b -> Widget n
              -- ^ A function to render this form field. Parameters are
              -- whether the field is currently focused, followed by the
              -- field state.
              , formFieldHandleEvent :: BrickEvent n e -> b -> EventM n b
              -- ^ An event handler for this field. This receives the
              -- event and the field state and returns a new field
              -- state.
              }

data FormFieldState s e n where
    FormFieldState :: { formFieldState :: b
                      , formFieldLens  :: Lens' s a
                      , formFields     :: [FormField a b e n]
                      , formFieldRenderHelper :: Widget n -> Widget n
                      } -> FormFieldState s e n

data Form s e n =
    Form { formFieldStates  :: [FormFieldState s e n]
         , formFocus        :: FocusRing n
         , formState        :: s
         }

infixr 5 @@=
(@@=) :: (Widget n -> Widget n) -> (s -> FormFieldState s e n) -> s -> FormFieldState s e n
(@@=) h mkFs s =
    let v = mkFs s
    in v { formFieldRenderHelper = h . (formFieldRenderHelper v) }

newForm :: [s -> FormFieldState s e n]
        -> s
        -> Form s e n
newForm mkEs s =
    let es = mkEs <*> pure s
    in Form { formFieldStates = es
            , formFocus       = focusRing $ concat $ formFieldNames <$> es
            , formState       = s
            }

formFieldNames :: FormFieldState s e n -> [n]
formFieldNames (FormFieldState _ _ fields _) = formFieldName <$> fields

checkboxField :: (Ord n, Show n)
              => Lens' s Bool
              -> n
              -> T.Text
              -> s
              -> FormFieldState s e n
checkboxField stLens name label initialState =
    let initVal = initialState ^. stLens

        handleEvent (MouseDown n _ _ _) s | n == name = return $ not s
        handleEvent (VtyEvent (EvKey (KChar ' ') [])) s = return $ not s
        handleEvent _ s = return s

    in FormFieldState { formFieldState        = initVal
                      , formFields            = [ FormField name Just
                                                            (renderCheckbox label name)
                                                            handleEvent
                                                ]
                      , formFieldLens         = stLens
                      , formFieldRenderHelper = id
                      }

renderCheckbox :: T.Text -> n -> Bool -> Bool -> Widget n
renderCheckbox label n foc val =
    let addAttr = if foc then withDefAttr focusedFormInputAttr else id
    in clickable n $
       addAttr $
       (str $ "[" <> (if val then "X" else " ") <> "] ") <+> txt label

radioField :: (Ord n, Show n, Eq a)
           => Lens' s a
           -> [(a, n, T.Text)]
           -> s
           -> FormFieldState s e n
radioField stLens options initialState =
    let initVal = initialState ^. stLens

        lookupOptionValue n =
            let results = filter (\(_, n', _) -> n' == n) options
            in case results of
                [(val, _, _)] -> Just val
                _ -> Nothing

        handleEvent _ (MouseDown n _ _ _) s =
            case lookupOptionValue n of
                Nothing -> return s
                Just v -> return v
        handleEvent new (VtyEvent (EvKey (KChar ' ') [])) _ = return new
        handleEvent _ _ s = return s

        optionFields = mkOptionField <$> options
        mkOptionField (val, name, label) =
            FormField name
                      Just
                      (renderRadio val name label)
                      (handleEvent val)

    in FormFieldState { formFieldState        = initVal
                      , formFields            = optionFields
                      , formFieldLens         = stLens
                      , formFieldRenderHelper = id
                      }

renderRadio :: (Eq a) => a -> n -> T.Text -> Bool -> a -> Widget n
renderRadio val name label foc cur =
    let addAttr = if foc
                  then withDefAttr focusedFormInputAttr
                  else id
        isSet = val == cur
    in clickable name $
       addAttr $
       hBox [ str "["
            , str $ if isSet then "*" else " "
            , txt $ "] " <> label
            ]

editField :: (Ord n, Show n)
          => Lens' s a
          -> n
          -> Maybe Int
          -> (a -> T.Text)
          -> ([T.Text] -> Maybe a)
          -> ([T.Text] -> Widget n)
          -> (Widget n -> Widget n)
          -> s
          -> FormFieldState s e n
editField stLens n limit ini val renderText wrapEditor initialState =
    let initVal = mk $ initialState ^. stLens
        mk = editor n limit . ini
        handleEvent (VtyEvent e) ed = handleEditorEvent e ed
        handleEvent _ ed = return ed

    in FormFieldState { formFieldState = initVal
                      , formFields     = [ FormField n
                                                     (val . getEditContents)
                                                     (\b e -> wrapEditor $ renderEditor renderText b e)
                                                     handleEvent
                                         ]
                      , formFieldLens  = stLens
                      , formFieldRenderHelper = id
                      }

editShowableField :: (Ord n, Show n, Read a, Show a)
                  => Lens' s a
                  -> n
                  -> s
                  -> FormFieldState s e n
editShowableField stLens n =
    let ini = T.pack . show
        val = readMaybe . T.unpack . T.intercalate "\n"
        limit = Just 1
        renderText = txt . T.unlines
    in editField stLens n limit ini val renderText id

editTextField :: (Ord n, Show n)
              => Lens' s T.Text
              -> n
              -> Maybe Int
              -> s
              -> FormFieldState s e n
editTextField stLens n limit =
    let ini = id
        val = Just . T.intercalate "\n"
        renderText = txt . T.intercalate "\n"
    in editField stLens n limit ini val renderText id

editPasswordField :: (Ord n, Show n)
                  => Lens' s T.Text
                  -> n
                  -> s
                  -> FormFieldState s e n
editPasswordField stLens n =
    let ini = id
        val = Just . T.concat
        limit = Just 1
        renderText = toPassword
    in editField stLens n limit ini val renderText id

toPassword :: [T.Text] -> Widget a
toPassword s = txt $ T.replicate (T.length $ T.concat s) "*"

formAttr :: AttrName
formAttr = "brickForm"

invalidFormInputAttr :: AttrName
invalidFormInputAttr = formAttr <> "invalidInput"

focusedFormInputAttr :: AttrName
focusedFormInputAttr = formAttr <> "focusedInput"

allFieldsValid :: Form s e n -> Bool
allFieldsValid = null . invalidFields

invalidFields :: Form s e n -> [n]
invalidFields f = concat $ getInvalidFields <$> formFieldStates f

getInvalidFields :: FormFieldState s e n -> [n]
getInvalidFields (FormFieldState st _ fs _) =
    let gather (FormField n validate _ _) =
            if (isNothing $ validate st) then [n] else []
    in concat $ gather <$> fs

renderForm :: (Eq n) => Form s e n -> Widget n
renderForm (Form es fr _) =
    vBox $ renderFormFieldState fr <$> es

renderFormFieldState :: (Eq n)
                     => FocusRing n
                     -> FormFieldState s e n
                     -> Widget n
renderFormFieldState fr (FormFieldState st _ fields helper) =
    let renderFields [] = []
        renderFields ((FormField n validate renderField _):fs) =
            let maybeInvalid = if isJust $ validate st
                               then id
                               else forceAttr invalidFormInputAttr
                foc = Just n == focusGetCurrent fr
            in maybeInvalid (renderField foc st) : renderFields fs
    in helper $ vBox $ renderFields fields

handleFormEvent :: (Eq n) => BrickEvent n e -> Form s e n -> EventM n (Form s e n)
handleFormEvent (VtyEvent (EvKey (KChar '\t') [])) f =
    return $ f { formFocus = focusNext $ formFocus f }
handleFormEvent (VtyEvent (EvKey KBackTab [])) f =
    return $ f { formFocus = focusPrev $ formFocus f }
handleFormEvent e@(MouseDown n _ _ _) f =
    handleFormFieldEvent n e $ f { formFocus = focusSetCurrent n (formFocus f) }
handleFormEvent e@(MouseUp n _ _) f =
    handleFormFieldEvent n e $ f { formFocus = focusSetCurrent n (formFocus f) }
handleFormEvent e f =
    case focusGetCurrent (formFocus f) of
        Nothing -> return f
        Just n  -> handleFormFieldEvent n e f

handleFormFieldEvent :: (Eq n) => n -> BrickEvent n e -> Form s e n -> EventM n (Form s e n)
handleFormFieldEvent n ev f = findFieldState [] (formFieldStates f)
    where
        findFieldState _ [] = return f
        findFieldState prev (e:es) =
            case e of
                FormFieldState st stLens fields helper -> do
                    let findField [] = return Nothing
                        findField (field:rest) =
                            case field of
                                FormField n' validate _ handleFunc | n == n' -> do
                                    nextSt <- handleFunc ev st
                                    -- If the new state validates, go ahead and update
                                    -- the form state with it.
                                    case validate nextSt of
                                        Nothing -> return $ Just (nextSt, Nothing)
                                        Just newSt -> return $ Just (nextSt, Just newSt)
                                _ -> findField rest

                    result <- findField fields
                    case result of
                        Nothing -> findFieldState (prev <> [e]) es
                        Just (newSt, maybeSt) ->
                            let newFieldState = FormFieldState newSt stLens fields helper
                            in return $ f { formFieldStates = prev <> [newFieldState] <> es
                                          , formState = case maybeSt of
                                              Nothing -> formState f
                                              Just s  -> formState f & stLens .~ s
                                          }