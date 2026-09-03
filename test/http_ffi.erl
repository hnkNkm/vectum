-module(http_ffi).
-export([send_raw/2]).

%% Connect to 127.0.0.1:Port, send the raw HTTP packet, and return the
%% full response bytes. Unread request bodies are fine: the server answers
%% (e.g. 413) and closes the connection, which ends the receive loop.
send_raw(Port, Packet) when is_integer(Port), is_binary(Packet) ->
    {ok, Sock} = gen_tcp:connect(
        {127, 0, 0, 1}, Port, [binary, {active, false}, {packet, raw}], 5000
    ),
    ok = gen_tcp:send(Sock, Packet),
    Resp = recv_all(Sock, <<>>),
    gen_tcp:close(Sock),
    Resp.

recv_all(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Data} -> recv_all(Sock, <<Acc/binary, Data/binary>>);
        {error, closed} -> Acc;
        {error, timeout} -> Acc
    end.
