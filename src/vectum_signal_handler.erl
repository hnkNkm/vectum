-module(vectum_signal_handler).
-behaviour(gen_event).

%% erl_signal_server に登録するシグナルハンドラ。
%% SIGTERM / SIGINT を graceful shutdown シーケンスへ委譲する。

-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2]).

init([Fun]) ->
    {ok, {Fun, false}}.

%% 二重配送でも shutdown シーケンスは一度だけ走らせる。
%% 完了後は halt するため、生存中の重複は無視でよい。
handle_event(Signal, {Fun, false}) when Signal =:= sigterm; Signal =:= sigint ->
    _ = spawn(fun() -> Fun() end),
    {ok, {Fun, true}};
handle_event(Signal, State) when Signal =:= sigterm; Signal =:= sigint ->
    {ok, State};
handle_event(_Other, State) ->
    {ok, State}.

handle_call(_Request, Fun) ->
    {ok, ok, Fun}.

handle_info(_Info, Fun) ->
    {ok, Fun}.

terminate(_Reason, _Fun) ->
    ok.
