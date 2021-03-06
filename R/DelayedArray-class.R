### =========================================================================
### DelayedArray objects
### -------------------------------------------------------------------------


setClass("DelayedArray",
    contains="Array",
    representation(
        seed="ANY",              # An array-like object expected to satisfy
                                 # the "seed contract" i.e. to support dim(),
                                 # dimnames(), and subset_seed_as_array().

        index="list",            # List (possibly named) of subscripts as
                                 # positive integer vectors, one vector per
                                 # seed dimension. *Missing* list elements
                                 # are allowed and represented by NULLs.

        metaindex="integer",     # Index into the "index" slot specifying the
                                 # seed dimensions to keep.

        delayed_ops="list",      # List of delayed operations. See below
                                 # for the details.

        is_transposed="logical"  # Is the object considered to be transposed
                                 # with respect to the seed?
    ),
    prototype(
        seed=new("array"),
        index=list(NULL),
        metaindex=1L,
        is_transposed=FALSE
    )
)

### Extending DataTable gives us a few things for free (head(), tail(),
### etc...)
setClass("DelayedMatrix",
    contains=c("DelayedArray", "DataTable"),
    prototype=prototype(
        seed=new("matrix"),
        index=list(NULL, NULL),
        metaindex=1:2
    )
)

### Automatic coercion method from DelayedArray to DelayedMatrix silently
### returns a broken object (unfortunately these dummy automatic coercion
### methods don't bother to validate the object they return). So we overwrite
### it.
setAs("DelayedArray", "DelayedMatrix",
    function(from) new("DelayedMatrix", from)
)

### For internal use only.
setGeneric("matrixClass", function(x) standardGeneric("matrixClass"))

setMethod("matrixClass", "DelayedArray", function(x) "DelayedMatrix")


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Validity
###

.validate_DelayedArray <- function(x)
{
    x_dim <- dim(x@seed)
    x_ndim <- length(x_dim)
    ## 'seed' slot.
    if (x_ndim == 0L)
        return(wmsg2("'x@seed' must have dimensions"))
    ## 'index' slot.
    if (length(x@index) != x_ndim)
        return(wmsg2("'x@index' must have one list element per dimension ",
                     "in 'x@seed'"))
    if (!all(S4Vectors:::sapply_isNULL(x@index) |
             vapply(x@index, is.integer, logical(1), USE.NAMES=FALSE)))
        return(wmsg2("every list element in 'x@index' must be either NULL ",
                     "or an integer vector"))
    ## 'metaindex' slot.
    if (length(x@metaindex) == 0L)
        return(wmsg2("'x@metaindex' cannot be empty"))
    if (S4Vectors:::anyMissingOrOutside(x@metaindex, 1L, x_ndim))
        return(wmsg2("all values in 'x@metaindex' must be >= 1 ",
                     "and <= 'length(x@index)'"))
    if (!isStrictlySorted(x@metaindex))
        return(wmsg2("'x@metaindex' must be strictly sorted"))
    if (!all(get_Nindex_lengths(x@index, x_dim)[-x@metaindex] == 1L))
        return(wmsg2("all the dropped dimensions in 'x' must be equal to 1"))
    ## 'is_transposed' slot.
    if (!isTRUEorFALSE(x@is_transposed))
        return(wmsg2("'x@is_transposed' must be TRUE or FALSE"))
    TRUE
}

setValidity2("DelayedArray", .validate_DelayedArray)

### TODO: Move this to S4Vectors and make it the validity method for DataTable
### object.
.validate_DelayedMatrix <- function(x)
{
    if (length(dim(x)) != 2L)
        return(wmsg2("'x' must have exactly 2 dimensions"))
    TRUE
}

setValidity2("DelayedMatrix", .validate_DelayedMatrix)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Constructor
###

### NOT exported but used in HDF5Array!
new_DelayedArray <- function(seed=new("array"), Class="DelayedArray")
{
    seed <- remove_pristine_DelayedArray_wrapping(seed)
    seed_ndim <- length(dim(seed))
    if (seed_ndim == 2L)
        Class <- matrixClass(new(Class))
    index <- vector(mode="list", length=seed_ndim)
    new2(Class, seed=seed, index=index, metaindex=seq_along(index))
}

setGeneric("DelayedArray", function(seed) standardGeneric("DelayedArray"))

setMethod("DelayedArray", "ANY", function(seed) new_DelayedArray(seed))

### Calling DelayedArray() on a DelayedArray object is a no-op.
setMethod("DelayedArray", "DelayedArray", function(seed) seed)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### seed()
###

setGeneric("seed", function(x) standardGeneric("seed"))

setMethod("seed", "DelayedArray", function(x) x@seed)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Pristine objects
###
### A pristine DelayedArray object is an object that does not carry any
### delayed operation on it. In other words, it's in sync with (i.e. reflects
### the content of) its seed.
###

### NOT exported but used in HDF5Array!
### Note that false negatives happen when 'x' carries delayed operations that
### do nothing, but that's ok.
is_pristine <- function(x)
{
    ## 'x' should not carry any delayed operation on it, that is, all the
    ## DelayedArray slots must be in their original state.
    x2 <- new_DelayedArray(seed(x))
    class(x) <- class(x2) <- "DelayedArray"
    identical(x, x2)
}

### Remove the DelayedArray wrapping (or nested wrappings) from around the
### seed if the wrappings are pristine.
remove_pristine_DelayedArray_wrapping <- function(x)
{
    if (!(is(x, "DelayedArray") && is_pristine(x)))
        return(x)
    remove_pristine_DelayedArray_wrapping(seed(x))
}

### When a pristine DelayedArray derived object (i.e. an HDF5Array object) is
### about to be touched, we first need to downgrade it to a DelayedArray or
### DelayedMatrix *instance*.
downgrade_to_DelayedArray_or_DelayedMatrix <- function(x)
{
    if (is(x, "DelayedMatrix"))
        return(as(x, "DelayedMatrix"))
    as(x, "DelayedArray")
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### dim()
###

### dim() getter.

.get_DelayedArray_dim_before_transpose <- function(x)
{
    get_Nindex_lengths(x@index, dim(seed(x)))[x@metaindex]
}
.get_DelayedArray_dim <- function(x)
{
    ans <- .get_DelayedArray_dim_before_transpose(x)
    if (x@is_transposed)
        ans <- rev(ans)
    ans
}

setMethod("dim", "DelayedArray", .get_DelayedArray_dim)

setMethod("isEmpty", "DelayedArray", function(x) any(dim(x) == 0L))

### dim() setter.

.normalize_dim_replacement_value <- function(value, x_dim)
{
    if (is.null(value))
        stop(wmsg("you can't do that, sorry"))
    if (!is.numeric(value))
        stop(wmsg("the supplied dim vector must be numeric"))
    if (length(value) == 0L)
        stop(wmsg("the supplied dim vector cannot be empty"))
    if (!is.integer(value))
        value <- as.integer(value)
    if (S4Vectors:::anyMissingOrOutside(value, 0L))
        stop(wmsg("the supplied dim vector cannot contain negative ",
                  "or NA values"))
    if (length(value) > length(x_dim))
        stop(wmsg("too many dimensions supplied"))
    prod1 <- prod(value)
    prod2 <- prod(x_dim)
    if (prod1 != prod2)
        stop(wmsg("the supplied dims [product ", prod1, "] do not match ",
                  "the length of object [", prod2, "]"))
    unname(value)
}

.map_new_to_old_dim <- function(new_dim, old_dim, x_class)
{
    idx1 <- which(new_dim != 1L)
    idx2 <- which(old_dim != 1L)

    cannot_map_msg <- wmsg(
        "Cannot map the supplied dim vector to the current dimensions of ",
        "the object. On a ", x_class, " object, the dim() setter can only ",
        "be used to drop some of the ineffective dimensions (the dimensions ",
        "equal to 1 are the ineffective dimensions)."
    )

    can_map <- function() {
        if (length(idx1) != length(idx2))
            return(FALSE)
        if (length(idx1) == 0L)
            return(TRUE)
        if (!all(new_dim[idx1] == old_dim[idx2]))
            return(FALSE)
        tmp <- idx2 - idx1
        tmp[[1L]] >= 0L && isSorted(tmp)
    }
    if (!can_map())
        stop(cannot_map_msg)

    new2old <- seq_along(new_dim) +
        rep.int(c(0L, idx2 - idx1), diff(c(1L, idx1, length(new_dim) + 1L)))

    if (new2old[[length(new2old)]] > length(old_dim))
        stop(cannot_map_msg)

    new2old
}

.set_DelayedArray_dim <- function(x, value)
{
    x_dim <- dim(x)
    value <- .normalize_dim_replacement_value(value, x_dim)
    new2old <- .map_new_to_old_dim(value, x_dim, class(x))
    stopifnot(identical(value, x_dim[new2old]))  # sanity check
    if (x@is_transposed) {
        x_metaindex <- rev(rev(x@metaindex)[new2old])
    } else {
        x_metaindex <- x@metaindex[new2old]
    }
    if (!identical(x@metaindex, x_metaindex)) {
        x <- downgrade_to_DelayedArray_or_DelayedMatrix(x)
        x@metaindex <- x_metaindex
    }
    if (length(dim(x)) == 2L)
        x <- as(x, matrixClass(x))
    x
}

setReplaceMethod("dim", "DelayedArray", .set_DelayedArray_dim)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### drop()
###

setMethod("drop", "DelayedArray",
    function(x)
    {
        x_dim <- dim(x)
        dim(x) <- x_dim[x_dim != 1L]
        x
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### dimnames()
###

### dimnames() getter.

.get_DelayedArray_dimnames_before_transpose <- function(x)
{
    x_seed_dimnames <- dimnames(seed(x))
    ans <- lapply(x@metaindex,
                  get_Nindex_names_along,
                    Nindex=x@index,
                    dimnames=x_seed_dimnames)
    if (all(S4Vectors:::sapply_isNULL(ans)))
        return(NULL)
    ans
}
.get_DelayedArray_dimnames <- function(x)
{
    ans <- .get_DelayedArray_dimnames_before_transpose(x)
    if (x@is_transposed)
        ans <- rev(ans)
    ans
}

setMethod("dimnames", "DelayedArray", .get_DelayedArray_dimnames)

### dimnames() setter.

.normalize_dimnames_replacement_value <- function(value, ndim)
{
    if (is.null(value))
        return(vector("list", length=ndim))
    if (!is.list(value))
        stop("the supplied dimnames must be a list")
    if (length(value) > ndim)
        stop(wmsg("the supplied dimnames is longer ",
                  "than the number of dimensions"))
    if (length(value) <- ndim)
        length(value) <- ndim
    value
}

.set_DelayedArray_dimnames <- function(x, value)
{
    value <- .normalize_dimnames_replacement_value(value, length(x@metaindex))
    if (x@is_transposed)
        value <- rev(value)

    ## We quickly identify a no-op situation. While doing so, we are careful to
    ## not trigger a copy of the "index" slot (which can be big). The goal is
    ## to make a no-op like 'dimnames(x) <- dimnames(x)' as fast as possible.
    x_seed_dimnames <- dimnames(seed(x))
    touched_midx <- which(mapply(
        function(N, names)
            !identical(
                get_Nindex_names_along(x@index, x_seed_dimnames, N),
                names
            ),
        x@metaindex, value,
        USE.NAMES=FALSE
    ))
    if (length(touched_midx) == 0L)
        return(x)  # no-op

    x <- downgrade_to_DelayedArray_or_DelayedMatrix(x)
    touched_idx <- x@metaindex[touched_midx]
    x_seed_dim <- dim(seed(x))
    x@index[touched_idx] <- mapply(
        function(N, names) {
            i <- x@index[[N]]
            if (is.null(i))
                i <- seq_len(x_seed_dim[[N]])  # expand 'i'
            setNames(i, names)
        },
        touched_idx, value[touched_midx],
        SIMPLIFY=FALSE, USE.NAMES=FALSE
    )
    x
}

setReplaceMethod("dimnames", "DelayedArray", .set_DelayedArray_dimnames)

### names() getter & setter.

.get_DelayedArray_names <- function(x)
{
    if (length(dim(x)) != 1L)
        return(NULL)
    dimnames(x)[[1L]]
}

setMethod("names", "DelayedArray", .get_DelayedArray_names)

.set_DelayedArray_names <- function(x, value)
{
    if (length(dim(x)) != 1L) {
        if (!is.null(value))
            stop(wmsg("setting the names of a ", class(x), " object ",
                      "with more than 1 dimension is not supported"))
        return(x)
    }
    dimnames(x)[[1L]] <- value
    x
}

setReplaceMethod("names", "DelayedArray", .set_DelayedArray_names)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Transpose
###

### The actual transposition of the data is delayed i.e. it will be realized
### on the fly only when as.array() (or as.vector() or as.matrix()) is called
### on 'x'.
setMethod("t", "DelayedArray",
    function(x)
    {
        x <- downgrade_to_DelayedArray_or_DelayedMatrix(x)
        x@is_transposed <- !x@is_transposed
        x
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Management of delayed operations
###
### The 'delayed_ops' slot represents the list of delayed operations op1, op2,
### etc... Each delayed operation is itself represented by a list of length 4:
###   1) The name of the function to call (e.g. "+" or "log").
###   2) The list of "left arguments" i.e. the list of arguments to place
###      before the array in the function call.
###   3) The list of "right arguments" i.e. the list of arguments to place
###      after the array in the function call.
###   4) A single logical. Indicates the dimension along which the (left or
###      right) argument of the function call needs to be recycled when the
###      operation is actually executed (done by .execute_delayed_ops() which
###      is called by as.array()). FALSE: along the 1st dim; TRUE: along
###      the last dim; NA: no recycling. Recycling is only supported for
###      function calls with 2 arguments (i.e. the array and the recycled
###      argument) at the moment.
###      
### Each operation must return an array of the same dimensions as the original
### array.
###

register_delayed_op <- function(x, FUN, Largs=list(), Rargs=list(),
                                        recycle_along_last_dim=NA)
{
    if (isTRUEorFALSE(recycle_along_last_dim)) {
        nLargs <- length(Largs)
        nRargs <- length(Rargs)
        ## Recycling is only supported for function calls with 2 arguments
        ## (i.e. the array and the recycled argument) at the moment.
        stopifnot(nLargs + nRargs == 1L)
        partially_recycled_arg <- if (nLargs == 1L) Largs[[1L]] else Rargs[[1L]]
        stopifnot(length(partially_recycled_arg) == nrow(x))
    }
    delayed_op <- list(FUN, Largs, Rargs, recycle_along_last_dim)
    x <- downgrade_to_DelayedArray_or_DelayedMatrix(x)
    x@delayed_ops <- c(x@delayed_ops, list(delayed_op))
    x
}

.subset_delayed_op_args <- function(delayed_op, i, subset_along_last_dim)
{
    recycle_along_last_dim <- delayed_op[[4L]]
    if (is.na(recycle_along_last_dim)
     || recycle_along_last_dim != subset_along_last_dim)
        return(delayed_op)
    Largs <- delayed_op[[2L]]
    Rargs <- delayed_op[[3L]]
    nLargs <- length(Largs)
    nRargs <- length(Rargs)
    stopifnot(nLargs + nRargs == 1L)
    if (nLargs == 1L) {
        new_arg <- extractROWS(Largs[[1L]], i)
        delayed_op[[2L]] <- list(new_arg)
    } else {
        new_arg <- extractROWS(Rargs[[1L]], i)
        delayed_op[[3L]] <- list(new_arg)
    }
    if (length(new_arg) == 1L)
        delayed_op[[4L]] <- NA
    delayed_op
}

.subset_delayed_ops_args <- function(delayed_ops, i, subset_along_last_dim)
    lapply(delayed_ops, .subset_delayed_op_args, i, subset_along_last_dim)

### 'a' is the ordinary array returned by the "combining" operator.
.execute_delayed_ops <- function(a, delayed_ops)
{
    a_dim <- dim(a)
    first_dim <- a_dim[[1L]]
    last_dim <- a_dim[[length(a_dim)]]
    a_len <- length(a)
    if (a_len == 0L) {
        p1 <- p2 <- 0L
    } else {
        p1 <- a_len / first_dim
        p2 <- a_len / last_dim
    }

    recycle_arg <- function(partially_recycled_arg, recycle_along_last_dim) {
        if (recycle_along_last_dim) {
            stopifnot(length(partially_recycled_arg) == last_dim)
            rep(partially_recycled_arg, each=p2)
        } else {
            stopifnot(length(partially_recycled_arg) == first_dim)
            rep.int(partially_recycled_arg, p1)
        }
    }

    prepare_call_args <- function(a, delayed_op) {
        Largs <- delayed_op[[2L]]
        Rargs <- delayed_op[[3L]]
        recycle_along_last_dim <- delayed_op[[4L]]
        if (isTRUEorFALSE(recycle_along_last_dim)) {
            nLargs <- length(Largs)
            nRargs <- length(Rargs)
            stopifnot(nLargs + nRargs == 1L)
            if (nLargs == 1L) {
                Largs <- list(recycle_arg(Largs[[1L]], recycle_along_last_dim))
            } else {
                Rargs <- list(recycle_arg(Rargs[[1L]], recycle_along_last_dim))
            }
        }
        c(Largs, list(a), Rargs)
    }

    for (delayed_op in delayed_ops) {
        FUN <- delayed_op[[1L]]
        call_args <- prepare_call_args(a, delayed_op)

        ## Perform the delayed operation.
        a <- do.call(FUN, call_args)

        ## Some vectorized operations on an ordinary array can drop the dim
        ## attribute (e.g. comparing a zero-col matrix with an atomic vector).
        a_new_dim <- dim(a)
        if (is.null(a_new_dim)) {
            ## Restore the dim attribute.
            dim(a) <- a_dim
        } else {
            ## Sanity check.
            stopifnot(identical(a_dim, a_new_dim))
        }
    }
    a
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Multi-dimensional single bracket subsetting
###
###     x[i_1, i_2, ..., i_n]
###
### Return an object of the same class as 'x' (endomorphism).
### 'user_Nindex' must be a "multidimensional subsetting Nindex" i.e. a
### list with one subscript per dimension in 'x'. Missing subscripts must
### be represented by NULLs.
###

.subset_DelayedArray_by_Nindex <- function(x, user_Nindex)
{
    stopifnot(is.list(user_Nindex))
    x_index <- x@index
    x_ndim <- length(x@metaindex)
    x_seed_dim <- dim(seed(x))
    x_seed_dimnames <- dimnames(seed(x))
    x_delayed_ops <- x@delayed_ops
    for (n in seq_along(user_Nindex)) {
        subscript <- user_Nindex[[n]]
        if (is.null(subscript))
            next
        n0 <- if (x@is_transposed) x_ndim - n + 1L else n
        N <- x@metaindex[[n0]]
        i <- x_index[[N]]
        if (is.null(i)) {
            i <- seq_len(x_seed_dim[[N]])  # expand 'i'
            names(i) <- get_Nindex_names_along(x_index, x_seed_dimnames, N)
        }
        subscript <- normalizeSingleBracketSubscript(subscript, i,
                                                     as.NSBS=TRUE)
        x_index[[N]] <- extractROWS(i, subscript)
        if (n0 == 1L)
            x_delayed_ops <- .subset_delayed_ops_args(x_delayed_ops, subscript,
                                                      FALSE)
        if (n0 == x_ndim)
            x_delayed_ops <- .subset_delayed_ops_args(x_delayed_ops, subscript,
                                                      TRUE)
    }
    if (!identical(x@index, x_index)) {
        x <- downgrade_to_DelayedArray_or_DelayedMatrix(x)
        x@index <- x_index
        if (!identical(x@delayed_ops, x_delayed_ops))
            x@delayed_ops <- x_delayed_ops
    }
    x
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### type()
###
### For internal use only.
###

setGeneric("type", function(x) standardGeneric("type"))

setMethod("type", "array", function(x) typeof(x))

### If 'x' is a DelayedArray object, 'type(x)' must always return the same
### as 'typeof(as.array(x))'.
setMethod("type", "DelayedArray",
    function(x)
    {
        user_Nindex <- as.list(integer(length(dim(x))))
        ## x0 <- x[0, ..., 0]
        x0 <- .subset_DelayedArray_by_Nindex(x, user_Nindex)
        typeof(as.array(x0, drop=TRUE))
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Linear single bracket subsetting
###
###     x[i]
###
### Return an atomic vector.
###

.subset_DelayedArray_by_1Dindex <- function(x, i)
{
    if (!is.numeric(i))
        stop(wmsg("1D-style subsetting of a DelayedArray object only ",
                  "accepts a numeric subscript at the moment"))
    if (length(i) == 0L) {
        user_Nindex <- as.list(integer(length(dim(x))))
        ## x0 <- x[0, ..., 0]
        x0 <- .subset_DelayedArray_by_Nindex(x, user_Nindex)
        return(as.vector(x0))
    }
    if (anyNA(i))
        stop(wmsg("1D-style subsetting of a DelayedArray object does ",
                  "not support NA indices yet"))
    if (min(i) < 1L)
        stop(wmsg("1D-style subsetting of a DelayedArray object only ",
                  "supports positive indices at the moment"))
    if (max(i) > length(x))
        stop(wmsg("subscript contains out-of-bounds indices"))
    if (length(i) == 1L)
        return(.get_DelayedArray_element(x, i))

    ## We want to walk only on the blocks that we actually need to visit so we
    ## don't use block_APPLY() or family because they walk on all the blocks.

    max_block_len <- get_max_block_length(type(x))
    spacings <- get_max_spacings_for_linear_blocks(dim(x), max_block_len)
    grid <- ArrayRegularGrid(dim(x), spacings)
    nblock <- length(grid)

    breakpoints <- cumsum(lengths(grid))
    part_idx <- get_part_index(i, breakpoints)
    split_part_idx <- split_part_index(part_idx, length(breakpoints))
    block_idx <- which(lengths(split_part_idx) != 0L)  # blocks to visit
    res <- lapply(block_idx, function(b) {
            if (get_verbose_block_processing())
                message("Visiting block ", b, "/", nblock, " ... ",
                        appendLF=FALSE)
            block <- extract_block(x, grid[[b]])
            if (!is.array(block))
                block <- as.array(block)
            block_ans <- block[split_part_idx[[b]]]
            if (get_verbose_block_processing())
                message("OK")
            block_ans
    })
    unlist(res, use.names=FALSE)[get_rev_index(part_idx)]
}


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### [
###

.subset_DelayedArray <- function(x, i, j, ..., drop=TRUE)
{
    if (missing(x))
        stop("'x' is missing")
    user_Nindex <- extract_Nindex_from_syscall(sys.call(), parent.frame())
    nsubscript <- length(user_Nindex)
    if (nsubscript != 0L && nsubscript != length(dim(x))) {
        if (nsubscript != 1L)
            stop("incorrect number of subscripts")
        return(.subset_DelayedArray_by_1Dindex(x, user_Nindex[[1L]]))
    }
    .subset_DelayedArray_by_Nindex(x, user_Nindex)
}
setMethod("[", "DelayedArray", .subset_DelayedArray)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### [<-
###

.filling_error_msg <- c(
    "filling a DelayedArray object 'x' with a value (i.e. 'x[] <- value') ",
    "is supported only when 'value' is an atomic vector and 'length(value)' ",
    "is a divisor of 'nrow(x)'"
)

.subassign_error_msg <- c(
    "subassignment to a DelayedArray object 'x' (i.e. 'x[i] <- value') is ",
    "supported only when the subscript 'i' is a logical DelayedArray object ",
    "with the same dimensions as 'x' and when 'value' is a scalar (i.e. an ",
    "atomic vector of length 1)"
)

.fill_DelayedArray_with_value <- function(x, value)
{
    if (!(is.vector(value) && is.atomic(value)))
        stop(wmsg(.filling_error_msg))
    value_len <- length(value)
    if (value_len == 1L)
        return(register_delayed_op(x, `[<-`, Rargs=list(value=value)))
    x_len <- length(x)
    if (value_len > x_len)
        stop(wmsg("'value' is longer than 'x'"))
    x_nrow <- nrow(x)
    if (x_nrow != 0L) {
        if (value_len == 0L || x_nrow %% value_len != 0L)
            stop(wmsg(.filling_error_msg))
        value <- rep(value, length.out=x_nrow)
    }
    register_delayed_op(x, `[<-`, Rargs=list(value=value),
                                  recycle_along_last_dim=x@is_transposed)
}

.subassign_DelayedArray <- function(x, i, j, ..., value)
{
    if (missing(x))
        stop("'x' is missing")
    user_Nindex <- extract_Nindex_from_syscall(sys.call(), parent.frame())
    nsubscript <- length(user_Nindex)
    if (nsubscript == 0L)
        return(.fill_DelayedArray_with_value(x, value))
    if (nsubscript != 1L)
        stop(wmsg(.subassign_error_msg))
    i <- user_Nindex[[1L]]
    if (!(is(i, "DelayedArray") &&
          identical(dim(x), dim(i)) &&
          type(i) == "logical"))
        stop(wmsg(.subassign_error_msg))
    if (!(is.vector(value) && is.atomic(value) && length(value) == 1L))
        stop(wmsg(.subassign_error_msg))
    DelayedArray(new_ConformableSeedCombiner(x, i,
                                             COMBINING_OP=`[<-`,
                                             Rargs=list(value=value)))
}

setReplaceMethod("[", "DelayedArray", .subassign_DelayedArray)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Realization in memory
###
###     as.array(x)
###

### TODO: Do we actually need this? Using drop() should do it.
.reduce_array_dimensions <- function(x)
{
    x_dim <- dim(x)
    x_dimnames <- dimnames(x)
    effdim_idx <- which(x_dim != 1L)  # index of effective dimensions
    if (length(effdim_idx) >= 2L) {
        ## changing dim(x) results in a memory copy which is slow
        ## here we catch if it will actually change anything and avoid if not
        if( !(identical(dim(x), x_dim[effdim_idx])) ) {
            dim(x) <- x_dim[effdim_idx]
            dimnames(x) <- x_dimnames[effdim_idx]
        }
    } else {
        dim(x) <- NULL
        if (length(effdim_idx) == 1L)
            names(x) <- x_dimnames[[effdim_idx]]
    }
    x
}

### Realize the object i.e. execute all the delayed operations and turn the
### object back into an ordinary array.
.from_DelayedArray_to_array <- function(x, drop=FALSE)
{
    if (!isTRUEorFALSE(drop))
        stop("'drop' must be TRUE or FALSE")
    ans <- subset_seed_as_array(seed(x), unname(x@index))
    dim_ans <- .get_DelayedArray_dim_before_transpose(x)
    if(!identical(dim(ans), dim_ans)) {
        dim(ans) <- dim_ans
    }
    ans <- .execute_delayed_ops(ans, x@delayed_ops)
    dimnames_ans <- .get_DelayedArray_dimnames_before_transpose(x)
    if(!identical(dimnames(ans), dimnames_ans)) {
        dimnames(ans) <- dimnames_ans
    }
    if (drop)
        ans <- .reduce_array_dimensions(ans)
    ## Base R doesn't support transposition of an array of arbitrary dimension
    ## (generalized transposition) so the call to t() below will fail if 'ans'
    ## has more than 2 dimensions. If we want as.array() to work on a
    ## transposed DelayedArray object of arbitrary dimension, we need to
    ## implement our own generalized transposition of an ordinary array.
    if (x@is_transposed) {
        if (length(dim(ans)) > 2L)
            stop("can't do as.array() on this object, sorry")
        ans <- t(ans)
    }
    ans
}

### S3/S4 combo for as.array.DelayedArray
as.array.DelayedArray <- function(x, ...)
    .from_DelayedArray_to_array(x, ...)
setMethod("as.array", "DelayedArray", .from_DelayedArray_to_array)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Other coercions based on as.array()
###

slicing_tip <- c(
    "Consider reducing its number of effective dimensions by slicing it ",
    "first (e.g. x[8, 30, , 2, ]). Make sure that all the indices used for ",
    "the slicing have length 1 except at most 2 of them which can be of ",
    "arbitrary length or missing."
)

.from_DelayedArray_to_matrix <- function(x)
{
    x_dim <- dim(x)
    if (sum(x_dim != 1L) > 2L)
        stop(wmsg(class(x), " object with more than 2 effective dimensions ",
                  "cannot be coerced to a matrix. ", slicing_tip))
    ans <- as.array(x, drop=TRUE)
    if (length(x_dim) == 2L) {
        if(!identical(dim(ans), x_dim)) {
            dim(ans) <- x_dim
            dimnames(ans) <- dimnames(x)
        }
    } else {
        as.matrix(ans)
    }
    ans
}

### S3/S4 combo for as.matrix.DelayedArray
as.matrix.DelayedArray <- function(x, ...) .from_DelayedArray_to_matrix(x, ...)
setMethod("as.matrix", "DelayedArray", .from_DelayedArray_to_matrix)

### S3/S4 combo for as.data.frame.DelayedArray
as.data.frame.DelayedArray <- function(x, row.names=NULL, optional=FALSE, ...)
    as.data.frame(as.array(x, drop=TRUE),
                  row.names=row.names, optional=optional, ...)
setMethod("as.data.frame", "DelayedArray", as.data.frame.DelayedArray)

### S3/S4 combo for as.vector.DelayedArray
as.vector.DelayedArray <- function(x, mode="any")
{
    ans <- as.array(x, drop=TRUE)
    as.vector(ans, mode=mode)
}
setMethod("as.vector", "DelayedArray", as.vector.DelayedArray)

### S3/S4 combo for as.logical.DelayedArray
as.logical.DelayedArray <- function(x, ...) as.vector(x, mode="logical", ...)
setMethod("as.logical", "DelayedArray", as.logical.DelayedArray)

### S3/S4 combo for as.integer.DelayedArray
as.integer.DelayedArray <- function(x, ...) as.vector(x, mode="integer", ...)
setMethod("as.integer", "DelayedArray", as.integer.DelayedArray)

### S3/S4 combo for as.numeric.DelayedArray
as.numeric.DelayedArray <- function(x, ...) as.vector(x, mode="numeric", ...)
setMethod("as.numeric", "DelayedArray", as.numeric.DelayedArray)

### S3/S4 combo for as.complex.DelayedArray
as.complex.DelayedArray <- function(x, ...) as.vector(x, mode="complex", ...)
setMethod("as.complex", "DelayedArray", as.complex.DelayedArray)

### S3/S4 combo for as.character.DelayedArray
as.character.DelayedArray <- function(x, ...) as.vector(x, mode="character", ...)
setMethod("as.character", "DelayedArray", as.character.DelayedArray)

### S3/S4 combo for as.raw.DelayedArray
as.raw.DelayedArray <- function(x) as.vector(x, mode="raw")
setMethod("as.raw", "DelayedArray", as.raw.DelayedArray)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Coercion to sparse matrix (requires the Matrix package)
###

.from_DelayedMatrix_to_dgCMatrix <- function(from)
{
    idx <- which(from != 0L)
    array_ind <- arrayInd(idx, dim(from))
    i <- array_ind[ , 1L]
    j <- array_ind[ , 2L]
    x <- from[idx]
    Matrix::sparseMatrix(i, j, x=x, dims=dim(from), dimnames=dimnames(from))
}

setAs("DelayedMatrix", "dgCMatrix", .from_DelayedMatrix_to_dgCMatrix)
setAs("DelayedMatrix", "sparseMatrix", .from_DelayedMatrix_to_dgCMatrix)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### [[
###

.get_DelayedArray_element <- function(x, i)
{
    i <- normalizeDoubleBracketSubscript(i, x)
    user_Nindex <- as.list(arrayInd(i, dim(x)))
    as.vector(.subset_DelayedArray_by_Nindex(x, user_Nindex))
}

### Only support linear subscripting at the moment.
### TODO: Support multidimensional subscripting e.g. x[[5, 15, 2]] or
### x[["E", 15, "b"]].
setMethod("[[", "DelayedArray",
    function(x, i, j, ...)
    {
        dots <- list(...)
        if (length(dots) > 0L)
            dots <- dots[names(dots) != "exact"]
        if (!missing(j) || length(dots) > 0L)
            stop("incorrect number of subscripts")
        .get_DelayedArray_element(x, i)
    }
)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Show
###

setMethod("show", "DelayedArray", show_compact_array)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Combining and splitting
###

### Note that combining arrays with c() is NOT an endomorphism!
setMethod("c", "DelayedArray",
    function (x, ..., recursive=FALSE)
    {
        if (!identical(recursive, FALSE))
            stop(wmsg("\"c\" method for DelayedArray objects ",
                      "does not support the 'recursive' argument"))
        if (missing(x)) {
            objects <- list(...)
        } else {
            objects <- list(x, ...)
        }
        combine_array_objects(objects)
    }
)

setMethod("splitAsList", "DelayedArray",
    function(x, f, drop=FALSE, ...)
        splitAsList(as.vector(x), f, drop=drop, ...)
)

### S3/S4 combo for split.DelayedArray
split.DelayedArray <- function(x, f, drop=FALSE, ...)
    splitAsList(x, f, drop=drop, ...)
setMethod("split", c("DelayedArray", "ANY"), split.DelayedArray)


### - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
### Binding
###
### We only support binding DelayedArray objects along the rows or the cols
### at the moment. No binding along an arbitrary dimension yet! (i.e. no
### "abind" method yet)
###

### arbind() and acbind()

.DelayedArray_arbind <- function(...)
{
    objects <- unname(list(...))
    dims <- get_dims_to_bind(objects, 1L)
    if (is.character(dims))
        stop(wmsg(dims))
    DelayedArray(new_SeedBinder(objects, 1L))
}

.DelayedArray_acbind <- function(...)
{
    objects <- unname(list(...))
    dims <- get_dims_to_bind(objects, 2L)
    if (is.character(dims))
        stop(wmsg(dims))
    DelayedArray(new_SeedBinder(objects, 2L))
}

setMethod("arbind", "DelayedArray", .DelayedArray_arbind)
setMethod("acbind", "DelayedArray", .DelayedArray_acbind)

### rbind() and cbind()

setMethod("rbind", "DelayedMatrix", .DelayedArray_arbind)
setMethod("cbind", "DelayedMatrix", .DelayedArray_acbind)

.as_DelayedMatrix_objects <- function(objects)
{
    lapply(objects,
        function(object) {
            if (length(dim(object)) != 2L)
                stop(wmsg("cbind() and rbind() are not supported on ",
                          "DelayedArray objects that don't have exactly ",
                          "2 dimensions. Please use acbind() or arnind() ",
                          "instead."))
            as(object, "DelayedMatrix")
        })
}

.DelayedArray_rbind <- function(...)
{
    objects <- .as_DelayedMatrix_objects(list(...))
    do.call("rbind", objects)
}

.DelayedArray_cbind <- function(...)
{
    objects <- .as_DelayedMatrix_objects(list(...))
    do.call("cbind", objects)
}

setMethod("rbind", "DelayedArray", .DelayedArray_rbind)
setMethod("cbind", "DelayedArray", .DelayedArray_cbind)

