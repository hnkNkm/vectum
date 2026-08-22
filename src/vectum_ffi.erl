-module(vectum_ffi).
-export([get_env/1, set_env/2, unset_env/1, halt/1]).
-export([
    shutdown_flag_get/0,
    shutdown_flag_set/1,
    worker_started/0,
    worker_finished/0,
    active_worker_count/0,
    install_shutdown_handler/1,
    registry_put_store/1,
    registry_get_store/0,
    registry_put_metrics/1,
    registry_get_metrics/0
]).

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

%% ------------------------------------------------------------------
%% Graceful shutdown (vectum/shutdown.gleam)
%% ------------------------------------------------------------------

shutdown_flag_get() ->
    persistent_term:get(vectum_shutting_down, false).

shutdown_flag_set(Value) ->
    _ = persistent_term:put(vectum_shutting_down, Value),
    nil.

worker_started() ->
    atomics:add(vectum_worker_counter(), 1, 1),
    nil.

worker_finished() ->
    atomics:add(vectum_worker_counter(), 1, -1),
    nil.

active_worker_count() ->
    atomics:get(vectum_worker_counter(), 1).

vectum_worker_counter() ->
    case persistent_term:get(vectum_active_workers, undefined) of
        undefined ->
            Ref = atomics:new(1, [{signed, true}]),
            _ = persistent_term:put(vectum_active_workers, Ref),
            Ref;
        Ref ->
            Ref
    end.

%% 既定の erl_signal_handler(init:stop するだけ)を外し、
%% graceful shutdown シーケンスへ委譲するハンドラに差し替える。
%% sigint は handle にできない環境があるため失敗を無視する。
install_shutdown_handler(Fun) ->
    _ = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
    ok = gen_event:add_handler(erl_signal_server, vectum_signal_handler, [Fun]),
    _ = os:set_signal(sigterm, handle),
    _ = catch os:set_signal(sigint, handle),
    nil.

%% ------------------------------------------------------------------
%% Registry (vectum/registry.gleam)
%% ------------------------------------------------------------------

registry_put_store(Value) ->
    _ = persistent_term:put(vectum_registry_store, Value),
    nil.

registry_get_store() ->
    case persistent_term:get(vectum_registry_store, undefined) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.

registry_put_metrics(Value) ->
    _ = persistent_term:put(vectum_registry_metrics, Value),
    nil.

registry_get_metrics() ->
    case persistent_term:get(vectum_registry_metrics, undefined) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.
