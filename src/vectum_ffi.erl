-module(vectum_ffi).
-export([get_env/1, set_env/2, unset_env/1, halt/1]).

get_env(Name) when is_binary(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

set_env(Name, Value) when is_binary(Name), is_binary(Value) ->
    true = os:putenv(binary_to_list(Name), binary_to_list(Value)),
    nil.

unset_env(Name) when is_binary(Name) ->
    os:unsetenv(binary_to_list(Name)),
    nil.

halt(Code) when is_integer(Code) ->
    erlang:halt(Code).
