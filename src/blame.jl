# Copied from base for use on 0.6 (only in base as of 0.7).
# Copyright (c) 2009-2016: Jeff Bezanson, Stefan Karpinski, Viral B. Shah, and other contributors:
using Base.LibGit2: GitHash, SignatureStruct, AbstractGitObject, REFCOUNT

"""
    LibGit2.BlameOptions

Matches the [`git_blame_options`](https://libgit2.github.com/libgit2/#HEAD/type/git_blame_options) struct.
"""
@Base.LibGit2.kwdef struct BlameOptions
    version::Cuint                    = 1
    flags::UInt32                     = 0
    min_match_characters::UInt16      = 20
    newest_commit::GitHash
    oldest_commit::GitHash
    min_line::Csize_t                 = 1
    max_line::Csize_t                 = 0
end

for (typ, owntyp, sup, cname) in [
    (:GitBlame,          :GitRepo,              :AbstractGitObject, :git_blame),
    ]

    if owntyp === nothing
        @eval mutable struct $typ <: $sup
            ptr::Ptr{Void}
            function $typ(ptr::Ptr{Void}, fin::Bool=true)
                # fin=false should only be used when the pointer should not be free'd
                # e.g. from within callback functions which are passed a pointer
                @assert ptr != C_NULL
                obj = new(ptr)
                if fin
                    Threads.atomic_add!(REFCOUNT, UInt(1))
                    finalizer(obj, Base.close)
                end
                return obj
            end
        end
    else
        @eval mutable struct $typ <: $sup
            owner::$owntyp
            ptr::Ptr{Void}
            function $typ(owner::$owntyp, ptr::Ptr{Void}, fin::Bool=true)
                @assert ptr != C_NULL
                obj = new(owner, ptr)
                if fin
                    Threads.atomic_add!(REFCOUNT, UInt(1))
                    finalizer(obj, Base.close)
                end
                return obj
            end
        end
        if isa(owntyp, Expr) && owntyp.args[1] == :Nullable
            @eval begin
                $typ(ptr::Ptr{Void}, fin::Bool=true) = $typ($owntyp(), ptr, fin)
                $typ(owner::$(owntyp.args[2]), ptr::Ptr{Void}, fin::Bool=true) =
                    $typ($owntyp(owner), ptr, fin)
            end
        end
    end
    @eval function Base.close(obj::$typ)
        if obj.ptr != C_NULL
            ccall(($(string(cname, :_free)), :libgit2), Void, (Ptr{Void},), obj.ptr)
            obj.ptr = C_NULL
            if Threads.atomic_sub!(REFCOUNT, UInt(1)) == 1
                # will the last finalizer please turn out the lights?
                ccall((:git_libgit2_shutdown, :libgit2), Cint, ())
            end
        end
    end
end


"""
    LibGit2.BlameHunk

Matches the [`git_blame_hunk`](https://libgit2.github.com/libgit2/#HEAD/type/git_blame_hunk) struct.
The fields represent:
    * `lines_in_hunk`: the number of lines in this hunk of the blame.
    * `final_commit_id`: the [`GitHash`](@ref) of the commit where this section was last changed.
    * `final_start_line_number`: the *one based* line number in the file where the
       hunk starts, in the *final* version of the file.
    * `final_signature`: the signature of the person who last modified this hunk. You will
       need to pass this to [`Signature`](@ref) to access its fields.
    * `orig_commit_id`: the [`GitHash`](@ref) of the commit where this hunk was first found.
    * `orig_path`: the path to the file where the hunk originated. This may be different
       than the current/final path, for instance if the file has been moved.
    * `orig_start_line_number`: the *one based* line number in the file where the
       hunk starts, in the *original* version of the file at `orig_path`.
    * `orig_signature`: the signature of the person who introduced this hunk. You will
       need to pass this to [`Signature`](@ref) to access its fields.
    * `boundary`: `'1'` if the original commit is a "boundary" commit (for instance, if it's
       equal to an oldest commit set in `options`).
"""
@Base.LibGit2.kwdef struct BlameHunk
    lines_in_hunk::Csize_t

    final_commit_id::GitHash
    final_start_line_number::Csize_t
    final_signature::Ptr{SignatureStruct}

    orig_commit_id::GitHash
    orig_path::Cstring
    orig_start_line_number::Csize_t
    orig_signature::Ptr{SignatureStruct}

    boundary::Char
end

function GitBlame(repo::GitRepo, path::AbstractString; options::BlameOptions=BlameOptions())
    blame_ptr_ptr = Ref{Ptr{Void}}(C_NULL)
    @Base.LibGit2.check ccall((:git_blame_file, :libgit2), Cint,
                  (Ptr{Ptr{Void}}, Ptr{Void}, Cstring, Ptr{BlameOptions}),
                   blame_ptr_ptr, repo.ptr, path, Ref(options))
    return GitBlame(repo, blame_ptr_ptr[])
end

function counthunks(blame::GitBlame)
    return ccall((:git_blame_get_hunk_count, :libgit2), Int32, (Ptr{Void},), blame.ptr)
end

function Base.getindex(blame::GitBlame, i::Integer)
    if !(1 <= i <= counthunks(blame))
        throw(BoundsError(blame, (i,)))
    end
    hunk_ptr = ccall((:git_blame_get_hunk_byindex, :libgit2),
                      Ptr{BlameHunk},
                      (Ptr{Void}, Csize_t), blame.ptr, i-1)
    return unsafe_load(hunk_ptr)
end

function Base.show(io::IO, blame_hunk::BlameHunk)
    println(io, "GitBlameHunk:")
    println(io, "Original path: ", unsafe_string(blame_hunk.orig_path))
    println(io, "Lines in hunk: ", blame_hunk.lines_in_hunk)
    println(io, "Final commit oid: ", blame_hunk.final_commit_id)
    print(io, "Final signature: ")
    show(io, Signature(blame_hunk.final_signature))
    println(io)
    println(io, "Original commit oid: ", blame_hunk.orig_commit_id)
    print(io, "Original signature: ")
    show(io, Signature(blame_hunk.orig_signature))
end
