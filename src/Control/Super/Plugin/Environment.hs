
-- | Provides the plugins monadic envionment,
--   access to the environment and message printing capabilities.
module Control.Super.Plugin.Environment
  ( -- * Supermonad Plugin Monad
    SupermonadPluginM
  , runSupermonadPlugin
  , runSupermonadPluginAndReturn
  , runTcPlugin
    -- * Supermonad Plugin Environment Access
  , getGivenConstraints, getWantedConstraints
  , getInstEnvs
  , getClassDictionary
  , getClass
  , isOptionalClass
  , getCustomState, putCustomState, modifyCustomState
  , getInstanceFor
  , addTypeEqualities, addTypeEquality
  , addTyVarEqualities, addTyVarEquality
  , getTypeEqualities, getTyVarEqualities
  , whenNoResults
  , addWarning, displayWarnings
  , throwPluginError, throwPluginErrorSDoc, catchPluginError
    -- * Debug and Error Output
  , assert, assertM
  , printErr, printMsg, printObj, printWarn
  , printConstraints
  ) where

import Data.List ( groupBy )

import Control.Monad ( when, unless, forM_ )
import Control.Monad.Reader ( ReaderT, runReaderT, asks )
import Control.Monad.State  ( StateT , runStateT , gets, modify )
import Control.Monad.Except ( ExceptT, runExceptT, throwError, catchError )
import Control.Monad.Trans.Class ( lift )

import Class ( Class )
-- import Module ( Module )
import InstEnv ( InstEnvs, ClsInst )
import Type ( TyVar, Type )
import TyCon ( TyCon )
import TcRnTypes ( Ct, TcPluginResult(..) )
import TcPluginM ( TcPluginM, tcPluginIO )
import qualified TcPluginM
import Outputable ( Outputable )
import SrcLoc ( srcSpanFileName_maybe )
import FastString ( unpackFS )
import qualified Outputable as O

import qualified Control.Super.Plugin.Log as L
import Control.Super.Plugin.Names ( PluginClassName )
import Control.Super.Plugin.Constraint
  ( GivenCt, WantedCt
  , constraintSourceLocation
  , mkDerivedTypeEqCt, mkDerivedTypeEqCtOfTypes )
import Control.Super.Plugin.ClassDict
  ( ClassDict
  , Optional
  , emptyClsDict
  , lookupClsDictClass )
import qualified Control.Super.Plugin.ClassDict as ClsD
import Control.Super.Plugin.InstanceDict
  ( InstanceDict, lookupInstDict )

-- -----------------------------------------------------------------------------
-- Plugin Monad
-- -----------------------------------------------------------------------------

-- | The error type used as result if the plugin fails.
type SupermonadError = O.SDoc

-- | The plugin monad.
type SupermonadPluginM s = ReaderT SupermonadPluginEnv 
                       ( StateT  (SupermonadPluginState s)
                       ( ExceptT SupermonadError TcPluginM
                       ) )

-- | The read-only environent of the plugin.
data SupermonadPluginEnv = SupermonadPluginEnv
  { smEnvGivenConstraints  :: [GivenCt]
  -- ^ The given and derived constraints (all of them).
  , smEnvWantedConstraints :: [WantedCt]
  -- ^ The wanted constraints (all of them).
  , smEnvClassDictionary :: ClassDict
  -- ^ Class dictionary of the environment.
  }

-- | The modifiable state of the plugin.
data SupermonadPluginState s = SupermonadPluginState 
  { smStateTyVarEqualities :: [(Ct, TyVar, Type)]
  -- ^ Equalities between type variables and types that have been derived by the plugin.
  , smStateTypeEqualities :: [(Ct, Type, Type)]
  -- ^ Eqaulities between types that have been derived by the plugin.
  , smStateWarningQueue :: [(String, O.SDoc)]
  -- ^ A queue of warnings that are only displayed if no progress could be made.
  , smStateCustom :: s
  -- ^ Custom state of the environment.
  }

-- | Runs the given supermonad plugin solver within the type checker plugin 
--   monad. Handles errors and produces a plugin result based on the environment.
runSupermonadPluginAndReturn 
  :: [GivenCt] -- ^ /Given/ and /derived/ constraints. 
  -> [WantedCt] -- ^ /Wanted/ constraints.
  -> SupermonadPluginM () (ClassDict, s) -- ^ Initialize the custom state of the plugin.
  -> SupermonadPluginM s a -- ^ Plugin code to run. Result value is ignored.
  -> TcPluginM TcPluginResult -- ^ The plugin result.
runSupermonadPluginAndReturn givenCts wantedCts initStateM pluginM = do
  eResult <- runSupermonadPlugin givenCts wantedCts initStateM $ do
    if not $ null wantedCts then do
      _ <- pluginM
      
      tyVarEqs <- getTyVarEqualities
      let tyVarEqCts = fmap (\(baseCt, tv, ty) -> mkDerivedTypeEqCt baseCt tv ty) tyVarEqs
      
      tyEqs <- getTypeEqualities
      let tyEqCts = fmap (\(baseCt, ta, tb) -> mkDerivedTypeEqCtOfTypes baseCt ta tb) tyEqs
      
      return $ TcPluginOk [] $ tyVarEqCts ++ tyEqCts
    else
      return $ TcPluginOk [] [] -- No result
  case eResult of
    Left err -> do
      L.printErr $ L.sDocToStr err
      return $ TcPluginOk [] [] -- No result
    Right solution -> return solution
  
-- | Runs the given supermonad plugin solver within the type checker plugin 
--   monad.
runSupermonadPlugin 
  :: [GivenCt] -- ^ /Given/ and /derived/ constraints. 
  -> [WantedCt] -- ^ /Wanted/ constraints.
  -> SupermonadPluginM () (ClassDict, s) -- ^ Initialize the custom state of the plugin.
  -> SupermonadPluginM s a -- ^ Plugin code to run.
  -> TcPluginM (Either SupermonadError a) -- ^ Either an error message or an actual plugin result.
runSupermonadPlugin givenCts wantedCts initStateM pluginM = do
  -- Try to construct the environment or throw errors
  let initEnv = SupermonadPluginEnv
        { smEnvGivenConstraints  = givenCts
        , smEnvWantedConstraints = wantedCts
        , smEnvClassDictionary   = emptyClsDict
        }
  let initState :: SupermonadPluginState ()
      initState = SupermonadPluginState 
        { smStateTyVarEqualities = []
        , smStateTypeEqualities  = []
        , smStateWarningQueue    = []
        , smStateCustom = ()
        }
  eInitResult <- runExceptT $ flip runStateT initState $ runReaderT initStateM initEnv
  case eInitResult of
    Left err -> return $ Left err
    Right ((smDict, customState), postInitState) -> do
      let env = initEnv { smEnvClassDictionary = smDict }
      let -- state :: SupermonadPluginState s
          state = SupermonadPluginState 
            { smStateTyVarEqualities = smStateTyVarEqualities postInitState
            , smStateTypeEqualities  = smStateTypeEqualities  postInitState
            , smStateWarningQueue    = smStateWarningQueue    postInitState
            , smStateCustom = customState
            }
      eResult <- runExceptT $ flip runStateT state $ runReaderT pluginM env
      return $ case eResult of
        Left  err -> Left err
        Right (a, _res) -> Right a


-- | Execute the given 'TcPluginM' computation within the plugin monad.
runTcPlugin :: TcPluginM a -> SupermonadPluginM s a
runTcPlugin = lift . lift . lift

-- -----------------------------------------------------------------------------
-- Plugin Environment Access
-- -----------------------------------------------------------------------------

-- | Returns the type class dictionary.
getClassDictionary :: SupermonadPluginM s ClassDict
getClassDictionary = asks smEnvClassDictionary

-- | Returns the plugins custom state.
getCustomState :: SupermonadPluginM s s
getCustomState = gets smStateCustom

-- | Writes the plugins custom state.
putCustomState :: s -> SupermonadPluginM s ()
putCustomState newS = modify (\s -> s { smStateCustom = newS })

-- | Modifies the plugins custom state.
modifyCustomState :: (s -> s) -> SupermonadPluginM s ()
modifyCustomState sf = modify (\s -> s { smStateCustom = sf (smStateCustom s) })

-- | Looks up a class by its name in the class dictionary of the 
--   plugin environment.
getClass :: PluginClassName -> SupermonadPluginM s (Maybe Class)
getClass clsName = lookupClsDictClass clsName <$> asks smEnvClassDictionary

-- | Check if the given class name refers that is optional in the solving process.
isOptionalClass :: PluginClassName -> SupermonadPluginM s Optional
isOptionalClass clsName = ClsD.isOptionalClass clsName <$> asks smEnvClassDictionary

-- | Returns all of the /given/ and /derived/ constraints of this plugin call.
getGivenConstraints :: SupermonadPluginM s [GivenCt]
getGivenConstraints = asks smEnvGivenConstraints

-- | Returns all of the wanted constraints of this plugin call.
getWantedConstraints :: SupermonadPluginM s [WantedCt]
getWantedConstraints = asks smEnvWantedConstraints

-- | Shortcut to access the instance environments.
getInstEnvs :: SupermonadPluginM s InstEnvs
getInstEnvs = runTcPlugin TcPluginM.getInstEnvs

-- | Retrieves the associated instance of the given type constructor and class.
getInstanceFor :: TyCon -> Class -> SupermonadPluginM InstanceDict (Maybe ClsInst)
getInstanceFor tc cls = fmap (lookupInstDict tc cls) getCustomState

-- | Add another type variable equality to the derived equalities.
addTyVarEquality :: Ct -> TyVar -> Type -> SupermonadPluginM s ()
addTyVarEquality ct tv ty = modify $ \s -> s { smStateTyVarEqualities = (ct, tv, ty) : smStateTyVarEqualities s }

-- | Add a list of type variable equalities to the derived equalities.
addTyVarEqualities :: [(Ct, TyVar, Type)] -> SupermonadPluginM s ()
addTyVarEqualities = mapM_ (\(ct, tv, ty) -> addTyVarEquality ct tv ty)

-- | Add another type equality to the derived equalities.
addTypeEquality :: Ct -> Type -> Type -> SupermonadPluginM s ()
addTypeEquality ct ta tb = modify $ \s -> s { smStateTypeEqualities = (ct, ta, tb) : smStateTypeEqualities s }

-- | Add a list of type equality to the derived equalities.
addTypeEqualities :: [(Ct, Type, Type)] -> SupermonadPluginM s ()
addTypeEqualities = mapM_ (\(ct, ta, tb) -> addTypeEquality ct ta tb)

-- | Returns all derived type variable equalities that were added to the results thus far.
getTyVarEqualities :: SupermonadPluginM s [(Ct, TyVar, Type)]
getTyVarEqualities = gets $ smStateTyVarEqualities

-- | Returns all derived type variable equalities that were added to the results thus far.
getTypeEqualities :: SupermonadPluginM s [(Ct, Type, Type)]
getTypeEqualities = gets $ smStateTypeEqualities

-- | Add a warning to the queue of warnings that will be displayed when no progress could be made.
addWarning :: String -> O.SDoc -> SupermonadPluginM s ()
addWarning msg details = modify $ \s -> s { smStateWarningQueue = (msg, details) : smStateWarningQueue s }

-- | Execute the given plugin code only if no plugin results were produced so far.
whenNoResults :: SupermonadPluginM s () -> SupermonadPluginM s ()
whenNoResults m = do
  tyVarEqs <- getTyVarEqualities
  tyEqs <- getTypeEqualities
  when (null tyVarEqs && null tyEqs) m

-- | Displays the queued warning messages if no progress has been made.
displayWarnings :: SupermonadPluginM s ()
displayWarnings = whenNoResults $ do
  warns <- gets smStateWarningQueue
  forM_ warns $ \(msg, details) -> do
    printWarn msg
    internalPrint $ L.smObjMsg $ L.sDocToStr details

-- -----------------------------------------------------------------------------
-- Plugin debug and error printing
-- -----------------------------------------------------------------------------

stringToSupermonadError :: String -> SupermonadError
stringToSupermonadError = O.text

-- | Assert the given condition. If the condition does not
--   evaluate to 'True', an error with the given message will
--   be thrown the plugin aborts.
assert :: Bool -> String -> SupermonadPluginM s ()
assert cond msg = unless cond $ throwPluginError msg

-- | Assert the given condition. Same as 'assert' but with
--   a monadic condition.
assertM :: SupermonadPluginM s Bool -> String -> SupermonadPluginM s ()
assertM condM msg = do
  cond <- condM
  assert cond msg

-- | Throw an error with the given message in the plugin.
--   This will abort all further actions.
throwPluginError :: String -> SupermonadPluginM s a
throwPluginError = throwError . stringToSupermonadError

-- | Throw an error with the given message in the plugin.
--   This will abort all further actions.
throwPluginErrorSDoc :: O.SDoc -> SupermonadPluginM s a
throwPluginErrorSDoc = throwError

-- | Catch an error that was thrown by the plugin.
catchPluginError :: SupermonadPluginM s a -> (SupermonadError -> SupermonadPluginM s a) -> SupermonadPluginM s a
catchPluginError = catchError

-- | Print some generic outputable object from the plugin (Unsafe).
printObj :: Outputable o => o -> SupermonadPluginM s ()
printObj = internalPrint . L.smObjMsg . L.pprToStr

-- | Print a message from the plugin.
printMsg :: String -> SupermonadPluginM s ()
printMsg = internalPrint . L.smDebugMsg

-- | Print an error message from the plugin.
printErr :: String -> SupermonadPluginM s ()
printErr = internalPrint . L.smErrMsg

-- | Print a warning message from the plugin.
printWarn :: String -> SupermonadPluginM s ()
printWarn = internalPrint . L.smWarnMsg

-- | Internal function for printing from within the monad.
internalPrint :: String -> SupermonadPluginM s ()
internalPrint = runTcPlugin . tcPluginIO . putStr

-- | Print the given string as if it was an object. This allows custom
--   formatting of object.
printFormattedObj :: String -> SupermonadPluginM s ()
printFormattedObj = internalPrint . L.smObjMsg

-- | Print the given constraints in the plugins custom format.
printConstraints :: [Ct] -> SupermonadPluginM s ()
printConstraints cts =
  forM_ groupedCts $ \(file, ctGroup) -> do
    printFormattedObj $ maybe "From unknown file:" (("From " ++) . (++":") . unpackFS) file
    mapM_ (printFormattedObj . L.formatConstraint) ctGroup
  where
    groupedCts = (\ctGroup -> (getCtFile $ head ctGroup, ctGroup)) <$> groupBy eqFileName cts
    eqFileName ct1 ct2 = getCtFile ct1 == getCtFile ct2
    getCtFile = srcSpanFileName_maybe . constraintSourceLocation
