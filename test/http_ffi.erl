-module(http_ffi).

%% ingress の HTTP レベルテスト用。raw TCP でリクエストを送り、
%% レスポンス全体を 1 つのバイナリで返す。
%% 接続・送信の失敗はクラッシュとして扱う(テストで失敗させたいため)。

-export([request/4]).

request(Host, Port, Data, TimeoutMs) ->
    %% Gleam の String はバイナリのため、charlist に変換する
    HostList = binary_to_list(Host),
    {ok, Sock} =
        gen_tcp:connect(HostList, Port, [binary, {packet, raw}, {active, false}], 5000),
    ok = gen_tcp:send(Sock, Data),
    Body = read_all(Sock, TimeoutMs, <<>>),
    gen_tcp:close(Sock),
    Body.

read_all(Sock, TimeoutMs, Acc) ->
    case gen_tcp:recv(Sock, 0, TimeoutMs) of
        {ok, Data} ->
            Acc2 = <<Acc/binary, Data/binary>>,
            %% チャンクedレスポンス終端を検出したら読み切り
            case binary:match(Acc2, <<"\r\n0\r\n\r\n">>) of
                nomatch -> read_all(Sock, TimeoutMs, Acc2);
                _ -> Acc2
            end;
        {error, closed} ->
            Acc;
        {error, timeout} ->
            Acc
    end.
