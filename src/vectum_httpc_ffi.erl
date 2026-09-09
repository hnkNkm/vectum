-module(vectum_httpc_ffi).
-export([post/5]).

%% One-shot HTTP POST via inets httpc for vectum/delivery.gleam.
%%
%% gleam_httpc は per-request HTTP options を [autoredirect, timeout] しか
%% 渡せないため、OTP の httpc 既定 (autoretry = infinity) がそのまま効き、
%% 503 + Retry-After に対してタイムアウト内に透過的に 1 回再送される (F1)。
%% vectum のリトライ勘定から隠れる再送を防ぐため {autoretry, 0} を明示し、
%% 503 はそのまま呼び出し元に返す。リダイレクト追従も gleam_httpc と
%% 同じく無効 ({autoredirect, false})。
%%
%% https はサーバ証明書をシステム CA ストアに対して検証する
%% (verify_peer + cacerts + ホスト名チェック) ことを明示する。
%% 戻り値: {ok, Status} | {error, Reason} (Reason は詳細文字列バイナリ)。

post(Url, Headers, ContentType, Body, TimeoutMs)
when is_binary(Url), is_list(Headers), is_binary(ContentType),
     is_binary(Body), is_integer(TimeoutMs) ->
    ok = ensure_started(inets),
    UrlList = unicode:characters_to_list(Url),
    ErlHeaders = [
        {unicode:characters_to_list(K), unicode:characters_to_list(V)}
     || {K, V} <- Headers
    ],
    HttpOptions = [
        {autoretry, 0},
        {timeout, TimeoutMs},
        {autoredirect, false}
        | tls_options(UrlList)
    ],
    Request = {
        UrlList,
        ErlHeaders,
        unicode:characters_to_list(ContentType),
        Body
    },
    Options = [{body_format, binary}, {socket_opts, [{ipfamily, inet6fb4}]}],
    case httpc:request(post, Request, HttpOptions, Options) of
        {ok, {{_, Status, _}, _, _}} when is_integer(Status) ->
            {ok, Status};
        {error, timeout} ->
            {error, <<"timeout">>};
        {error, {failed_connect, FailedOpts}} ->
            {error, iolist_to_binary(gleam_stdlib:inspect(failed_connect(FailedOpts)))};
        {error, Other} ->
            {error, iolist_to_binary(gleam_stdlib:inspect({httpc_error, Other}))}
    end.

%% https のみ SSL アプリを起動し、検証オプションを明示する。http の場合は
%% ssl オプションを渡さない(ssl アプリの起動も不要)。
tls_options(UrlList) ->
    case uri_string:parse(UrlList) of
        #{scheme := "https"} ->
            ok = ensure_started(ssl),
            [
                {ssl, [
                    {verify, verify_peer},
                    {cacerts, public_key:cacerts_get()},
                    {depth, 3},
                    {customize_hostname_check, [
                        {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
                    ]}
                ]}
            ];
        _ ->
            []
    end.

%% gleam_httpc と同じエラー表現 (FailedToConnect(Posix|TlsAlert, ...)) を
%% gleam_stdlib:inspect で描画して、従来と同じ詳細度の文字列にする。
%% 片方の IP ファミリの試行記録が無い形は gleam_httpc では panic になるが、
%% ここでは not_attempted として詳細を捨てずに残す。
failed_connect(FailedOpts) ->
    {failed_to_connect,
        ip_error(lists:keyfind(inet, 1, FailedOpts)),
        ip_error(lists:keyfind(inet6, 1, FailedOpts))}.

ip_error(false) ->
    {posix, <<"not_attempted">>};
ip_error({_, _, Reason}) ->
    normalise_ip_error(Reason).

normalise_ip_error({tls_alert, {Alert, Desc}}) when is_atom(Alert) ->
    {tls_alert, atom_to_binary(Alert), unicode:characters_to_binary(Desc)};
normalise_ip_error(Code) when is_atom(Code) ->
    {posix, atom_to_binary(Code)};
normalise_ip_error(Other) ->
    {posix, iolist_to_binary(io_lib:format("~0p", [Other]))}.

ensure_started(App) ->
    Key = {?MODULE, App},
    case persistent_term:get(Key, false) of
        true ->
            ok;
        false ->
            {ok, _} = application:ensure_all_started(App),
            persistent_term:put(Key, true),
            ok
    end.
