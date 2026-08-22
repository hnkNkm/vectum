-module(vectum_signal_handler).
-behaviour(gen_event).

%% erl_signal_server に登録するシグナルハンドラ。
%% SIGTERM / SIGINT を graceful shutdown シーケンスへ委譲する。

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

init([Fun]) ->
    {ok, Fun}.

handle_event(Signal, Fun) when Signal =:= sigterm; Signal =:= sigint ->
    _ = spawn(fun() -> Fun() end),
    {ok, Fun};
handle_event(_Other, Fun) ->
    {ok, Fun}.

handle_call(_Request, Fun) ->
    {ok, ok, Fun}.

handle_info(_Info, Fun) ->
    {ok, Fun}.

terminate(_Reason, _Fun) ->
    ok.
