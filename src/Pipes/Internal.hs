{-| This is an internal module, meaning that it is unsafe to import unless you
    understand the risks.

    This module provides a fast implementation by weakening the monad
    transformer laws.  These laws do not hold if you can pattern match on the
    constructors, as the following counter-example illustrates:

@
'lift' '.' 'return' = 'M' '.' 'return' '.' 'Pure'

'return' = 'Pure'

'lift' '.' 'return' /= 'return'
@

    You do not need to worry about this if you do not import this module, since
    the other modules in this library do not export the constructors or export
    any functions which can violate the monad transformer laws.
-}

{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# LANGUAGE Trustworthy           #-}

module Pipes.Internal (
    -- * Internal
      Proxy(..)
    , unsafeHoist
    , observe
    , X
    , closed
    ) where

import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.Monad.Morph (MFunctor(hoist), MMonad(embed))
import Control.Monad.Except (MonadError(..))
import Control.Monad.Catch (MonadThrow(..), MonadCatch(..), MonadMask(..))
import Control.Monad.Reader (MonadReader(..))
import Control.Monad.State (MonadState(..))
import Control.Monad.Writer (MonadWriter(..))
import Data.Void (Void)

#if MIN_VERSION_base(4,8,0)
import Control.Applicative (Alternative(..))
#else
import Control.Applicative
import Data.Monoid
#endif

import qualified Control.Monad.Catch
import qualified Data.Void

{-| A 'Proxy' is a monad transformer that receives and sends information on both
    an upstream and downstream interface.

    The type variables signify:

    * @a'@ and @a@ - The upstream interface, where @(a')@s go out and @(a)@s
      come in

    * @b'@ and @b@ - The downstream interface, where @(b)@s go out and @(b')@s
      come in

    * @m @ - The base monad

    * @r @ - The return value
-}
data Proxy a' a b' b m r
    = Request a' (a  -> Proxy a' a b' b m r )
    | Respond b  (b' -> Proxy a' a b' b m r )
    | M          (m    (Proxy a' a b' b m r))
    | Pure    r

instance Monad m => Functor (Proxy a' a b' b m) where
    fmap f p0 = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure    r      -> Pure (f r)

instance Monad m => Applicative (Proxy a' a b' b m) where
    pure      = Pure
    pf <*> px = go pf where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure    f      -> fmap f px
    m *> k = m >>= (\_ -> k)

instance Monad m => Monad (Proxy a' a b' b m) where
    return = pure
    (>>=)  = _bind

_bind
    :: Monad m
    => Proxy a' a b' b m r
    -> (r -> Proxy a' a b' b m r')
    -> Proxy a' a b' b m r'
p0 `_bind` f = go p0 where
    go p = case p of
        Request a' fa  -> Request a' (\a  -> go (fa  a ))
        Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
        M          m   -> M (m >>= \p' -> return (go p'))
        Pure    r      -> f r
{-# NOINLINE[1] _bind #-}

{-# RULES
    "_bind (Request a' k) f" forall a' k f .
        _bind (Request a' k) f = Request a' (\a  -> _bind (k a)  f);
    "_bind (Respond b  k) f" forall b  k f .
        _bind (Respond b  k) f = Respond b  (\b' -> _bind (k b') f);
    "_bind (M          m) f" forall m    f .
        _bind (M          m) f = M (m >>= \p -> return (_bind p f));
    "_bind (Pure    r   ) f" forall r    f .
        _bind (Pure    r   ) f = f r;
  #-}

instance (Monad m, Monoid r) => Monoid (Proxy a' a b' b m r) where
    mempty        = Pure mempty
    mappend p1 p2 = go p1 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure    r1     -> fmap (mappend r1) p2

instance MonadTrans (Proxy a' a b' b) where
    lift m = M (m >>= \r -> return (Pure r))

{-| 'unsafeHoist' is like 'hoist', but faster.

    This is labeled as unsafe because you will break the monad transformer laws
    if you do not pass a monad morphism as the first argument.  This function is
    safe if you pass a monad morphism as the first argument.
-}
unsafeHoist
    :: Monad m
    => (forall x . m x -> n x) -> Proxy a' a b' b m r -> Proxy a' a b' b n r
unsafeHoist nat = go
  where
    go p = case p of
        Request a' fa  -> Request a' (\a  -> go (fa  a ))
        Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
        M          m   -> M (nat (m >>= \p' -> return (go p')))
        Pure    r      -> Pure r
{-# INLINABLE unsafeHoist #-}

instance MFunctor (Proxy a' a b' b) where
    hoist nat p0 = go (observe p0)
      where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (nat (m >>= \p' -> return (go p')))
            Pure    r      -> Pure r

instance MMonad (Proxy a' a b' b) where
    embed f = go
      where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> f m >>= go
            Pure    r      -> Pure r

instance MonadIO m => MonadIO (Proxy a' a b' b m) where
    liftIO m = M (liftIO (m >>= \r -> return (Pure r)))

instance MonadReader r m => MonadReader r (Proxy a' a b' b m) where
    ask = lift ask
    local f = go
        where
          go p = case p of
              Request a' fa  -> Request a' (\a  -> go (fa  a ))
              Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
              Pure    r      -> Pure r
              M       m      -> M (local f m >>= \r -> return (go r))
    reader = lift . reader

instance MonadState s m => MonadState s (Proxy a' a b' b m) where
    get = lift get
    put = lift . put
    state = lift . state

instance MonadWriter w m => MonadWriter w (Proxy a' a b' b m) where
    writer = lift . writer
    tell = lift . tell
    listen p0 = go p0 mempty
      where
        go p w = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ) w)
            Respond b  fb' -> Respond b  (\b' -> go (fb' b') w)
            M       m      -> M (do
                (p', w') <- listen m
                return (go p' $! mappend w w') )
            Pure    r      -> Pure (r, w)

    pass p0 = go p0 mempty
      where
        go p w = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ) w)
            Respond b  fb' -> Respond b  (\b' -> go (fb' b') w)
            M       m      -> M (do
                (p', w') <- listen m
                return (go p' $! mappend w w') )
            Pure   (r, f)  -> M (pass (return (Pure r, \_ -> f w)))

instance MonadError e m => MonadError e (Proxy a' a b' b m) where
    throwError = lift . throwError
    catchError p0 f = go p0
      where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            Pure    r      -> Pure r
            M          m   -> M ((do
                p' <- m
                return (go p') ) `catchError` (\e -> return (f e)) )

instance MonadThrow m => MonadThrow (Proxy a' a b' b m) where
    throwM = lift . throwM
    {-# INLINE throwM #-}

instance MonadCatch m => MonadCatch (Proxy a' a b' b m) where
    catch p0 f = go p0
      where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            Pure    r      -> Pure r
            M          m   -> M ((do
                p' <- m
                return (go p') ) `Control.Monad.Catch.catch` (\e -> return (f e)) )

{-| The monad transformer laws are correct when viewed through the 'observe'
    function:

@
'observe' ('lift' ('return' r)) = 'observe' ('return' r)

'observe' ('lift' (m '>>=' f)) = 'observe' ('lift' m '>>=' 'lift' '.' f)
@

    This correctness comes at a small cost to performance, so use this function
    sparingly.

    This function is a convenience for low-level @pipes@ implementers.  You do
    not need to use 'observe' if you stick to the safe API.
-}
observe :: Monad m => Proxy a' a b' b m r -> Proxy a' a b' b m r
observe p0 = M (go p0) where
    go p = case p of
        Request a' fa  -> return (Request a' (\a  -> observe (fa  a )))
        Respond b  fb' -> return (Respond b  (\b' -> observe (fb' b')))
        M          m'  -> m' >>= go
        Pure    r      -> return (Pure r)
{-# INLINABLE observe #-}

-- | The empty type, used to close output ends
type X = Void

-- | Use 'closed' to \"handle\" impossible outputs
closed :: X -> a
closed = Data.Void.absurd
{-# INLINABLE closed #-}
