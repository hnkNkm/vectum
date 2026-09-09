-module(tls_ffi).
-export([start/0, stop/1, request_count/1, control_get/1]).

%% Local HTTPS test server presenting a self-signed certificate (generated
%% with public_key:pkix_test_data/1), bound to 127.0.0.1:0. Used by the F2
%% TLS-verification regression tests in delivery_test.gleam:
%%
%%   - a vectum send_http POST must be rejected at the client (verify_peer
%%     against the system CA store cannot trust the self-signed cert), so the
%%     server never sees a complete HTTP request;
%%   - control_get/2 (httpc with {verify, verify_none}) proves the listener
%%     itself works and that the rejection is caused by verification.
%%
%% Each accepted TLS connection is answered once with 200 and closed.

-define(TAB, tls_ffi_tab).
-define(ACCEPT_TIMEOUT, 1000).

start() ->
    ok = ensure_table(),
    {ok, _} = application:ensure_all_started(ssl),
    ChainConf = #{
        root => [{digest, sha256}],
        intermediates => [],
        peer => [{key, {rsa, 2048, 65537}}, {digest, sha256}]
    },
    #{server_config := ServerConf0} =
        public_key:pkix_test_data(#{
            server_chain => ChainConf,
            client_chain => ChainConf
        }),
    ServerConf = [
        binary,
        {active, false},
        {reuseaddr, true},
        {ip, {127, 0, 0, 1}}
        | ServerConf0
    ],
    {ok, Listen} = ssl:listen(0, ServerConf),
    {ok, {_Addr, Port}} = ssl:sockname(Listen),
    Pid = spawn(fun() -> loop(Listen, 0) end),
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

%% Positive control: the same self-signed server must answer a request that
%% skips verification. Returns the HTTP status, or 0 on any failure.
control_get(Port) when is_integer(Port) ->
    {ok, _} = application:ensure_all_started(inets),
    Url = lists:flatten(
        io_lib:format("https://127.0.0.1:~p/events", [Port])
    ),
    case
        httpc:request(
            get,
            {Url, []},
            [
                {autoretry, 0},
                {timeout, 5000},
                {autoredirect, false},
                {ssl, [{verify, verify_none}]}
            ],
            [{body_format, binary}]
        )
    of
        {ok, {{_, Status, _}, _, _}} -> Status;
        _ -> 0
    end.

ensure_table() ->
    case ets:info(?TAB) of
        undefined ->
            _ = ets:new(?TAB, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.

loop(Listen, Count) ->
    receive
        {count, From} ->
            From ! {count_resp, Count},
            loop(Listen, Count)
    after 0 ->
            case ssl:transport_accept(Listen, ?ACCEPT_TIMEOUT) of
                {ok, TlsSock} ->
                    NewCount = handle_connection(TlsSock, Count),
                    loop(Listen, NewCount);
                {error, timeout} ->
                    loop(Listen, Count);
                {error, closed} ->
                    ok
            end
    end.

%% TLS handshake failures (e.g. the client rejecting the certificate) do not
%% count as HTTP requests.
handle_connection(TlsSock, Count) ->
    case ssl:handshake(TlsSock, 5000) of
        {ok, _} ->
            _ = read_request(TlsSock),
            _ = ssl:send(
                TlsSock,
                <<"HTTP/1.1 200 OK\r\n"
                  "Content-Length: 0\r\n"
                  "Connection: close\r\n"
                  "\r\n">>
            ),
            _ = ssl:close(TlsSock),
            Count + 1;
        {error, _} ->
            _ = ssl:close(TlsSock),
            Count
    end.

%% Read until the request head plus any Content-Length body has arrived.
read_request(Sock) ->
    recv_until_complete(Sock, <<>>).

recv_until_complete(Sock, Acc) ->
    case request_complete(Acc) of
        true ->
            ok;
        false ->
            case ssl:recv(Sock, 0, 5000) of
                {ok, Data} ->
                    recv_until_complete(Sock, <<Acc/binary, Data/binary>>);
                {error, _} ->
                    ok
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
