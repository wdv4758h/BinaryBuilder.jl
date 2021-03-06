if Compat.Sys.islinux()

using VT100
using BinaryBuilder
using Compat.Test

# Create fake terminal to communicate with BinaryBuilder over
pty = VT100.create_pty(false)
ins, outs = Base.TTY(pty.slave; readable=true), Base.TTY(pty.slave; readable=false)

# Helper function to create a state, assign input/output streams, assign platforms, etc...
function BinaryBuilder.WizardState(ins::Base.TTY, outs::Base.TTY)
    state = BinaryBuilder.WizardState()
    state.ins = ins
    state.outs = outs
    state.platforms = supported_platforms()
    return state
end

# Helper function to try something and panic if it doesn't work
do_try(f) = try
    f()
catch e
    bt = catch_backtrace()
    Base.display_error(stderr, e, bt)

    # If a do_try fails, panic
    Base.Test.@test false
end


# Test the download stage
## Tarballs
using HTTP

r = HTTP.Router()
tar_libfoo() = read(`tar czf - -C $(Pkg.dir("BinaryBuilder","test"))/build_tests libfoo`)
function serve_tgz(req)
    HTTP.Response(200, tar_libfoo())
end
HTTP.register!(r, "/*/source.tar.gz", HTTP.HandlerFunction(serve_tgz))
server = HTTP.Server(r)
@async HTTP.serve(server, ip"127.0.0.1", 14444; verbose=false)

# Test one tar.gz download
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step2
    t = @async do_try(()->BinaryBuilder.step2(state))
    # URL
    write(pty.master, "http://127.0.0.1:14444/a/source.tar.gz\n")
    # Would you like to download additional sources?
    write(pty.master, "N\n")
    # Do you require any (binary) dependencies ? 
    write(pty.master, "N\n")
    # Wait for that step to complete
    wait(t)
end

# Test two tar.gz download
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step2
    t = @async do_try(()->BinaryBuilder.step2(state))
    # URL
    write(pty.master, "http://127.0.0.1:14444/a/source.tar.gz\n")
    # Would you like to download additional sources?
    write(pty.master, "y\n")
    write(pty.master, "http://127.0.0.1:14444/b/source.tar.gz\n")
    # Would you like to download additional sources?
    write(pty.master, "N\n")
    # Do you require any (binary) dependencies ? 
    write(pty.master, "N\n")
    # Wait for that step to complete
    wait(t)
end

# We're done with the server
put!(server.in, HTTP.Servers.KILL)

# Package up libfoo and dump a tarball in /tmp
tempspace = tempname()
mkdir(tempspace)
local tar_hash
open(joinpath(tempspace, "source.tar.gz"), "w") do f
    data = tar_libfoo()
    tar_hash = BinaryProvider.sha256(data)
    write(f, data)
end

# Test step3 success path
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step3
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    t = @async do_try(()->BinaryBuilder.step34(state))
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
    write(pty.master, "libfoo\nfooifier\n")
    wait(t)
end

# Test download with a broken symlink that used to kill the wizard
# https://github.com/JuliaPackaging/BinaryBuilder.jl/issues/183
let state = BinaryBuilder.WizardState(ins, outs)
    # download tarball with known broken symlink
    bsym_url = "https://github.com/staticfloat/small_bin/raw/d846f4a966883e7cc032a84acf4fa36695d05482/broken_symlink/broken_symlink.tar.gz"
    bsym_hash = "470d47f1e6719df286dade223605e0c7e78e2740e9f0ecbfa608997d52a00445"
    bsym_path = joinpath(tempspace, "broken_symlink.tar.gz")
    download_verify(bsym_url, bsym_hash, bsym_path)
    
    state.step = :step3
    state.source_urls = [bsym_url]
    state.source_files = [bsym_path]
    state.source_hashes = [bsym_hash]
    t = @async do_try(()->BinaryBuilder.step34(state))

    # If we get this far we've already won, follow through for good measure
    write(pty.master, "mkdir -p \$WORKSPACE/destdir/bin\n")
    write(pty.master, "cp /bin/bash \$WORKSPACE/destdir/bin/\n")
    write(pty.master, "exit\n")
    # We do not want to edit the script now
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    readuntil(pty.master, "unique variable name for each build artifact:")
    # Name the 'binary artifact' `bash`:
    write(pty.master, "bash\n")

    # Wait for the step to complete
    wait(t)
end


# Clear anything waiting to be read on `pty.master`
readavailable(pty.master)

# These technically should wait until the terminal has been put into/come out
# of raw mode.  We could probably detect that, but good enough for now.
wait_for_menu(pty) = sleep(1)
wait_for_non_menu(pty) = sleep(1)

# Step 3 failure path (no binary in destdir -> return to build)
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step3
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    t = @async do_try(()->BinaryBuilder.step34(state))
    sleep(1)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "rm -rf \$prefix/*\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    wait_for_menu(pty)
    write(pty.master, "\r")
    wait_for_non_menu(pty)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "mkdir -p \$prefix/{lib,bin}\n")
    write(pty.master, "cp fooifier \$prefix/bin\n")
    write(pty.master, "cp libfoo.so \$prefix/lib\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
    write(pty.master, "libfoo\nfooifier\n")
    wait(t)
end

# Step 3 failure path (no binary in destdir -> start over)
let state = BinaryBuilder.WizardState(ins, outs)
    state.step = :step3
    state.source_urls = ["http://127.0.0.1:14444/a/source.tar.gz\n"]
    state.source_files = [joinpath(tempspace, "source.tar.gz")]
    state.source_hashes = [bytes2hex(tar_hash)]
    t = @async do_try(()->while state.step == :step3
        BinaryBuilder.step34(state)
    end)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "rm -rf \$prefix/*\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # How would you like to proceed
    wait_for_menu(pty)
    write(pty.master, "\e[B")
    sleep(1)
    write(pty.master, "\r")
    wait_for_non_menu(pty)
    write(pty.master, "cd libfoo/\n")
    write(pty.master, "make install\n")
    write(pty.master, "exit\n")
    readuntil(pty.master, "Would you like to edit this script now?")
    write(pty.master, "N\n")
    # Step 4
    write(pty.master, "ad")
    write(pty.master, "libfoo\nfooifier\n")
    wait(t)
end

rm(tempspace; force=true, recursive=true)

end

# Make sure canonicalization does what we expect
zmq_url = "https://github.com/zeromq/zeromq3-x/releases/download/v3.2.5/zeromq-3.2.5.tar.gz"
@test BinaryBuilder.canonicalize_source_url(zmq_url) == zmq_url
