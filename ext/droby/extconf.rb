require 'mkmf'
if RUBY_VERSION >= "1.9"
    $CFLAGS += " -DRUBY_IS_19"
end
create_makefile("roby_marshalling")

