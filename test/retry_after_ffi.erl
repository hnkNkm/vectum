-module(retry_after_ffi).
-export([start/0, start/1, request_count/1, stop/1]).

%% Local HTTP/1.1 test server for Retry-After delivery tests.
%%
%% Binds 127.0.0.1:0 (kernel-assigned port), then answers each accepted
%% connection exactly once and closes it. start/0 is the F1 regression
%% scenario (503 + Retry-After: 1 once, then 200). start/1 selects a named
%% scenario; response()/2 below maps the name to a canned response body.
%%
%% httpc (inets) transparently retries a 503 with a parseable Retry-After
%% once unless {autoretry, 0} is set, so a retrying client produces two
%% connections. request_count/1 reports how many requests arrived; stop/1
%% closes the listener.

-define(TAB, retry_after_ffi_tab).
-define(ACCEPT_TIMEOUT, 1000).

%% F1 regression: 1st request gets 503 + Retry-After: 1, later ones 200.
start() ->
    start(<<"f1_503">>).

start(Scenario) when is_binary(Scenario) ->
    ok = ensure_table(),
    {ok, Listen} = gen_tcp:listen(
        0,
        [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]
    ),
    {ok, Port} = inet:port(Listen),
    Pid = spawn(fun() -> loop(Listen, Scenario, 0) end),
    true = ets:insert(?TAB, {Port, Pid}),
    Port.

stop(Port) when is_integer(Port) ->
    case ets:lookup(?TAB, Port) of
        [{Port, Pid}] ->
            ets:delete(?TAB, Port),
            exit(Pid, kill),
            ok;
        [] ->
            ok
    end.

request_count(Port) when is_integer(Port) ->
    case ets:lookup(?TAB, Port) of
        [{Port, Pid}] ->
            Pid ! {count, self()},
            receive
                {count_resp, Count} -> Count
            after 2000 ->
                    -1
            end;
        [] ->
            -1
    end.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            _ = ets:new(?TAB, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

loop(Listen, Scenario, Count) ->
    receive
        {count, From} ->
            From ! {count_resp, Count},
            loop(Listen, Scenario, Count)
    after 0 ->
            case gen_tcp:accept(Listen, ?ACCEPT_TIMEOUT) of
                {ok, Sock} ->
                    _ = read_request(Sock),
                    ok = gen_tcp:send(Sock, response(Scenario, Count)),
                    gen_tcp:close(Sock),
                    loop(Listen, Scenario, Count + 1);
                {error, timeout} ->
                    loop(Listen, Scenario, Count);
                {error, closed} ->
                    ok
            end
    end.

%% Response bodies per scenario (one connection each; f1_503 switches to
%% 200 after the first request).
response(<<"f1_503">>, 0) ->
    <<"HTTP/1.1 503 Service Unavailable\r\n"
      "Retry-After: 1\r\n"
      "Content-Length: 0\r\n"
      "Connection: close\r\n"
      "\r\n">>;
response(<<"f1_503">>, _) ->
    ok_response(<<"200 OK">>);
response(<<"ra2">>, _) ->
    <<"HTTP/1.1 429 Too Many Requests\r\n"
      "Retry-After: 2\r\n"
      "Content-Length: 0\r\n"
      "Connection: close\r\n"
      "\r\n">>;
response(<<"malformed">>, _) ->
    <<"HTTP/1.1 429 Too Many Requests\r\n"
      "Retry-After: not-a-date\r\n"
      "Content-Length: 0\r\n"
      "Connection: close\r\n"
      "\r\n">>;
response(<<"past_date">>, _) ->
    %% 1 時間前の HTTP-date。system_time ベースで組み立てるためホストの
    %% タイムゾーン設定に依存しない。
    PastSec = erlang:system_time(second) - 3600,
    Past = calendar:system_time_to_universal_time(PastSec, second),
    <<"HTTP/1.1 429 Too Many Requests\r\n"
      "Retry-After: ", (list_to_binary(httpd_util:rfc1123_date(Past)))/binary,
      "\r\n"
      "Content-Length: 0\r\n"
      "Connection: close\r\n"
      "\r\n">>;
response(<<"huge">>, _) ->
    %% 999_999_999_999 秒 (24h 上限を大きく超過)。
    <<"HTTP/1.1 429 Too Many Requests\r\n"
      "Retry-After: 999999999999\r\n"
      "Content-Length: 0\r\n"
      "Connection: close\r\n"
      "\r\n">>;
response(<<"ok200">>, _) ->
    ok_response(<<"200 OK">>);
response(<<"bad400">>, _) ->
    ok_response(<<"400 Bad Request">>).

ok_response(ReasonPhrase) ->
    <<"HTTP/1.1 ", ReasonPhrase/binary, "\r\n"
      "Content-Length: 0\r\n"
      "Connection: close\r\n"
      "\r\n">>.

%% Read until the request head plus any Content-Length body has arrived, so
%% the response is not sent while the client is still writing. gen_tcp:recv
%% with length 0 returns whatever is buffered (head and body may share one
%% chunk), so the total accumulated size is what counts.
read_request(Sock) ->
    recv_until_complete(Sock, <<>>).

recv_until_complete(Sock, Acc) ->
    case request_complete(Acc) of
        true ->
            ok;
        false ->
            case gen_tcp:recv(Sock, 0, 5000) of
                {ok, Data} -> recv_until_complete(Sock, <<Acc/binary, Data/binary>>);
                {error, _} -> ok
            end
    end.

request_complete(Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            false;
        {_, HeadEnd} ->
            case content_length(binary:part(Acc, 0, HeadEnd)) of
                error -> true;
                {ok, Len} -> byte_size(Acc) >= HeadEnd + 4 + Len
            end
    end.

content_length(Head) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    content_length(Lines, error).

content_length([], Acc) ->
    Acc;
content_length([Line | Rest], Acc) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] ->
            case string:lowercase(Name) of
                <<"content-length">> ->
                    case catch binary_to_integer(string:trim(Value)) of
                        Len when is_integer(Len) -> {ok, Len};
                        _ -> content_length(Rest, Acc)
                    end;
                _ ->
                    content_length(Rest, Acc)
            end;
        _ ->
            content_length(Rest, Acc)
    end.
