{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# LANGUAGE TypeFamilies, DerivingVia, InstanceSigs, BangPatterns #-}

-- | This module provides an implementation for the typeclasses defined in
--   "Language.Souffle.Class".
--   It makes use of the low level Souffle C++ API to offer a much more
--   performant alternative implementation to the implementation in
--   "Language.Souffle.Interpreted".
--
--   This module is mainly intended to be used after the prototyping phase is
--   over since the iteration cycle is slower due to the additional
--   C++ compilation times.
module Language.Souffle.Compiled
  ( Program(..)
  , Fact(..)
  , Marshal(..)
  , Handle
  , SouffleM
  , MonadSouffle(..)
  , runSouffle
  ) where

import Prelude hiding ( init )

import Control.Monad.Except
import Control.Monad.RWS.Strict
import Control.Monad.Reader
import Data.Foldable ( traverse_ )
import Data.Proxy
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV
import Foreign.ForeignPtr
import Foreign.Ptr
import Language.Souffle.Class
import qualified Language.Souffle.Internal as Internal
import Language.Souffle.Marshal


-- | A datatype representing a handle to a datalog program.
--   The type parameter is used for keeping track of which program
--   type the handle belongs to for additional type safety.
newtype Handle prog = Handle (ForeignPtr Internal.Souffle)

-- | A monad for executing Souffle-related actions in.
newtype SouffleM a
  = SouffleM
  { runSouffle :: IO a  -- ^ Returns the underlying IO action.
  } deriving ( Functor, Applicative, Monad, MonadIO ) via IO

type Tuple = Ptr Internal.Tuple

-- | A monad used solely for marshalling and unmarshalling
--   between Haskell and Souffle Datalog.
newtype CMarshal a = CMarshal (ReaderT Tuple IO a)
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader Tuple)
  via ( ReaderT Tuple IO )

runM :: CMarshal a -> Tuple -> IO a
runM (CMarshal m) = runReaderT m
{-# INLINABLE runM #-}

instance MonadPush CMarshal where
  pushInt int = do
    tuple <- ask
    liftIO $ Internal.tuplePushInt tuple int
  {-# INLINABLE pushInt #-}

  pushString str = do
    tuple <- ask
    liftIO $ Internal.tuplePushString tuple str
  {-# INLINABLE pushString #-}

instance MonadPop CMarshal where
  popInt = do
    tuple <- ask
    liftIO $ Internal.tuplePopInt tuple
  {-# INLINABLE popInt #-}

  popString = do
    tuple <- ask
    liftIO $ Internal.tuplePopString tuple
  {-# INLINABLE popString #-}

class Collect c where
  collect :: Marshal a => Int -> ForeignPtr Internal.RelationIterator -> IO (c a)

instance Collect [] where
  collect factCount = go 0 factCount []
    where
      go idx count acc _ | idx == count = pure acc
      go idx count !acc !it = do
        tuple <- Internal.relationIteratorNext it
        result <- runM pop tuple
        go (idx + 1) count (result : acc) it
  {-# INLINABLE collect #-}

instance Collect V.Vector where
  collect factCount iterator = do
    vec <- MV.unsafeNew factCount
    go vec 0 factCount iterator
    where
      go vec idx count _ | idx == count = V.unsafeFreeze vec
      go vec idx count it = do
        tuple <- Internal.relationIteratorNext it
        result <- runM pop tuple
        MV.unsafeWrite vec idx result
        go vec (idx + 1) count it
  {-# INLINABLE collect #-}

instance MonadSouffle SouffleM where
  type Handler SouffleM = Handle
  type CollectFacts SouffleM c = Collect c

  init :: forall prog. Program prog
       => prog -> SouffleM (Maybe (Handle prog))
  init _ =
    let progName = programName (Proxy :: Proxy prog)
    in SouffleM $ fmap Handle <$> Internal.init progName
  {-# INLINABLE init #-}

  run (Handle prog) = SouffleM $ Internal.run prog
  {-# INLINABLE run #-}

  setNumThreads (Handle prog) numCores =
    SouffleM $ Internal.setNumThreads prog numCores
  {-# INLINABLE setNumThreads #-}

  getNumThreads (Handle prog) =
    SouffleM $ Internal.getNumThreads prog
  {-# INLINABLE getNumThreads #-}

  addFact :: forall a prog. (Fact a, ContainsFact prog a)
          => Handle prog -> a -> SouffleM ()
  addFact (Handle prog) fact = liftIO $ do
    let relationName = factName (Proxy :: Proxy a)
    relation <- Internal.getRelation prog relationName
    addFact' relation fact
  {-# INLINABLE addFact #-}

  addFacts :: forall t a prog . (Foldable t, Fact a, ContainsFact prog a)
           => Handle prog -> t a -> SouffleM ()
  addFacts (Handle prog) facts = liftIO $ do
    let relationName = factName (Proxy :: Proxy a)
    relation <- Internal.getRelation prog relationName
    traverse_ (addFact' relation) facts
  {-# INLINABLE addFacts #-}

  getFacts :: forall a c prog. (Fact a, ContainsFact prog a, Collect c)
           => Handle prog -> SouffleM (c a)
  getFacts (Handle prog) = SouffleM $ do
    let relationName = factName (Proxy :: Proxy a)
    relation <- Internal.getRelation prog relationName
    factCount <- Internal.countFacts relation
    Internal.getRelationIterator relation >>= collect factCount
  {-# INLINABLE getFacts #-}

  findFact :: forall a prog. (Fact a, ContainsFact prog a)
           => Handle prog -> a -> SouffleM (Maybe a)
  findFact (Handle prog) fact = SouffleM $ do
    let relationName = factName (Proxy :: Proxy a)
    relation <- Internal.getRelation prog relationName
    tuple <- Internal.allocTuple relation
    withForeignPtr tuple $ runM (push fact)
    found <- Internal.containsTuple relation tuple
    pure $ if found then Just fact else Nothing
  {-# INLINABLE findFact #-}

addFact' :: Fact a => Ptr Internal.Relation -> a -> IO ()
addFact' relation fact = do
  tuple <- Internal.allocTuple relation
  withForeignPtr tuple $ runM (push fact)
  Internal.addTuple relation tuple
{-# INLINABLE addFact' #-}


instance MonadSouffleFileIO SouffleM where
  loadFiles (Handle prog) = SouffleM . Internal.loadAll prog
  {-# INLINABLE loadFiles #-}

  writeFiles (Handle prog) = SouffleM . Internal.printAll prog
  {-# INLINABLE writeFiles #-}

