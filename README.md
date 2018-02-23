# FemtoCleaner

<p align="center"><img src="https://media.giphy.com/media/uVOTDhb5O5nW0/giphy.gif" alt="serious femtocleaning"></p>

FemtoCleaner cleans your julia projects by upgrading deprecated syntax, removing version compatibility workarounds and anything else that has a unique upgrade path. FemtoCleaner is designed to be as style-preserving as possible. It does not
perform code formatting. The logic behind recognizing and rewriting deprecated constructs
can be found in the [Deprecations.jl](https://github.com/JuliaComputing/Deprecations.jl) package,
which makes use of [CSTParser.jl](https://github.com/ZacLN/CSTParser.jl) under the hood.

# User Manual

To set up FemtoCleaner on your repository, go to https://github.com/integration/femtocleaner and click "Configure" to select the repositories you wish to add.

## Invoking FemtoCleaner

There are currently three triggers that cause FemtoCleaner to run over your
repository:
1. FemtoCleaner is installed on your repository for the first time
2. You change your repositories REQUIRE file to drop support for old versions of
julia
3. Manually, by opening an issue with the title `Run femtocleaner` on the desired
repository.

In all cases, femtocleaner, will clone your repository, upgrade any deprecations
it can and then open a pull request with the changes (in case 3, it will convert
the existing issue into a PR instead).

## Interacting with the PR

FemtoCleaner can automatically perform certain common commands in response to
user request in a PR review. These commands are invoked by creating a "Changes Requested"
review. FemtoCleaner will attempt to interpret each comment in such a review as
a request to perform an automated function. The following commands are currently
supported.

- `delete this entirely` - FemtoCleaner address the review by deleting the
  entire expression starting on the referenced line.
- `align arguments` - Assuming the preceding line contains a multi-line
  function signature, reformat the argument list, aligning each line to the
  opening parenthesis.
- `bad bot` - To be used when you deem the action taken by the bot to be incorrect.
  At present this will automatically open an issue on this repository.

If there are other such actions you would find useful, feel free to file an
issue or (even better) submit a PR.

## Privacy and Security

FemtoCleaner receives the content of many GitHub hooks. These contain certain publicly available details about the repository and the user who initiated the event. AttoBot will also make several subsequent queries via the public GitHub api to the repository in question. The contents of these may be retained in server logs.

In order to perform its function, FemtoCleaner requires read/write access to your
repository and its issues and pull requests. While FemtoCleaner runs in a sandboxed
environment and access to the underlying hardware is controlled and restricted,
you should be aware that you are extending these rights. If you are intending to
install FemtoCleaner on an organizational account, please ensure you are authorized
to extend these permissions to FemtoCleaner.

For the foregoing reasons, you should not install FemtoCleaner on a private
repository. Doing so may result in disclosure of contents of the private
repository.

Please note that the license applies to both the source code and your use of the
publicly hosted version thereof. In particular:

> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Running FemtoCleaner locally

It is possible to run FemtoCleaner locally (to fix, for example, deprecations in a private repository).

Install `FemtoCleaner` (currently working on Julia v0.6.x only) using

```jl
Pkg.clone("https://github.com/Keno/AbstractTrees.jl")
Pkg.clone("https://github.com/JuliaComputing/Deprecations.jl")
Pkg.clone("https://github.com/JuliaComputing/FemtoCleaner.jl")
```

A repository of Julia code can be cleaned using 

```jl
FemtoCleaner.cleanrepo(path::String; show_diff = true, delete_local = true)
```

This clones the repo located at `path`, which can be a file system path or a URL, to a temporary directory
and fix the deprecations. If `show_diff` is `true`, the diff from applying the deprecations is showed.
If `delete_local` is `true` the cleaned repo, is deleted when the function is finished.

# Developer Manual

You are encouraged to contribute changes to this repository. This software is
used by many people. Even minor changes in usability can make a big difference.
If you want to add additional interactions to the bot itself, this repository
is the right place. If you want to contribute additional deprecation rewrites,
please do so at https://github.com/JuliaComputing/Deprecations.jl.

## Deployment of the publicly hosted copy

The publicly hosted copy of FemtoCleaner is automatically deployed from the
master branch of this repository whenever a new commit to said branch is made.

## Setting up a development copy of femtocleaner

It is possible to set up a copy of femtocleaner to test changes to the codebase
before attempting to deploy them on the main version. To do so, you will need
a publicly routable server, with a copy of julia and this repository (and its
dependencies). You will then need to set up your own GitHub app at
https://github.com/settings/apps/new. Make sure to enter your server in the
"Webhook URL" portion of the form. By default, the app will listen on port
10000+app_id, where `app_id` is the ID GitHub assigns your app upon completion
of the registration process. Once you have set up your GitHub app, you will
need to download the private key and save it as `privkey.pem` in
`Pkg.dir("FemtoCleaner")`. Additionally, you should create a file named `app_id`,
containing the ID assigned to your app by GitHub (it will be visible on the
confirmation page once you have set up your app with GitHub). Then, you may
launch FemtoCleaner by running `julia -e 'using FemtoCleaner; FemtoCleaner.run_server()'`.
It is recommended that you set up a separate repository for testing your staging
copy that is not covered by the publicly hosted version, to avoid conflicting
updates. GitHub provides a powerful interface to see the messages delivered to
your app in the "Advanced" tab of your app's settings. In particular,
for interactive development, you may use the `Revise` package to reload
FemtoCleaner source code before every request (simply execute `using Revise` on
a separate line in the REPL before running FemtoCleaner). By editing the files
on the server and using GitHub's "Redeliver" option to replay events of interest,
a quick edit-debug cycle can be achieved.
