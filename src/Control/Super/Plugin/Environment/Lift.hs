
-- | Provides versions of functions written for 'TcPluginM'
--   that are lifted into 'SupermonadPluginM'.
module Control.Super.Plugin.Environment.Lift
  (
  -- * From "Control.Supermonad.Plugin.Evidence"
    produceEvidenceForCt
  , produceEvidenceFor
  , isPotentiallyInstantiatedCt
  -- * From "Control.Supermonad.Plugin.Utils"
  , partiallyApplyTyCons
  -- * From "Control.Supermonad.Plugin.Detect"
  , findClassesAndInstancesInScope
  ) where

import TcRnTypes ( Ct )
import TcEvidence ( EvTerm )
import Outputable ( SDoc )
import Type ( Type, TyVar )
import TyCon ( TyCon )
import InstEnv ( ClsInst )

import Control.Super.Plugin.Environment
  ( SupermonadPluginM
  , runTcPlugin
  , getGivenConstraints
  , throwPluginErrorSDoc
  )
import Control.Super.Plugin.ClassDict ( ClassDict, insertClsDict, insertOptionalClsDict )

import qualified Control.Super.Plugin.Utils as U
import qualified Control.Super.Plugin.Detect as D
import qualified Control.Super.Plugin.Evidence as E

-- | See 'E.produceEvidenceForCt'.
produceEvidenceForCt :: Ct -> SupermonadPluginM s (Either SDoc EvTerm)
produceEvidenceForCt ct = do
  givenCts <- getGivenConstraints
  runTcPlugin $ E.produceEvidenceForCt givenCts ct

-- | See 'E.produceEvidenceFor'.
produceEvidenceFor :: ClsInst -> [Type] -> SupermonadPluginM s (Either SDoc EvTerm)
produceEvidenceFor inst instArgs = do
  givenCts <- getGivenConstraints
  runTcPlugin $ E.produceEvidenceFor givenCts inst instArgs

-- | See 'E.isPotentiallyInstantiatedCt'.
isPotentiallyInstantiatedCt :: Ct -> [(TyVar, Either TyCon TyVar)] -> SupermonadPluginM s Bool
isPotentiallyInstantiatedCt ct assoc = do
  givenCts <- getGivenConstraints
  runTcPlugin $ E.isPotentiallyInstantiatedCt givenCts ct assoc

-- | See 'U.partiallyApplyTyCons'.
partiallyApplyTyCons :: [(TyVar, Either TyCon TyVar)] -> SupermonadPluginM s (Either SDoc [(TyVar, Type, [TyVar])])
partiallyApplyTyCons = runTcPlugin . U.partiallyApplyTyCons

-- | See 'D.findClassesAndInstancesInScope'. In addition to calling the 
--   function from the @Detect@ module it also throws an error if the call
--   fails. Otherwise, inserts the found classes and instances into the provided 
--   class dictionary and returns the updated dictionary.
findClassesAndInstancesInScope :: D.ClassQuery -> ClassDict -> SupermonadPluginM s ClassDict
findClassesAndInstancesInScope clsQuery oldClsDict = do
  let optQuery = D.isOptionalClassQuery clsQuery
  eFoundClsInsts <- runTcPlugin $ D.findClassesAndInstancesInScope clsQuery
  case eFoundClsInsts of
    Right [] | optQuery ->
      return $ foldr insertOptionalClsDict oldClsDict $ D.queriedClasses clsQuery
    Right clsInsts ->
      return $ foldr (\(clsName, cls, insts) -> insertClsDict clsName optQuery cls insts) oldClsDict clsInsts
    Left errMsg -> throwPluginErrorSDoc errMsg