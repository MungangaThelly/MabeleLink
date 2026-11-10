-module(mabelelink_auth).

-export([check/1]).

-define(MIN_TOKEN_BYTES, 32).

check(Req) ->
    case configured_token() of
        {error, unconfigured} -> {error, unconfigured};
        {ok, Expected} ->
            case cowboy_req:header(<<"authorization">>, Req) of
                <<"Bearer ", Provided/binary>> ->
                    case secure_equal(Expected, Provided) of
                        true -> ok;
                        false -> {error, unauthorized}
                    end;
                _ -> {error, unauthorized}
            end
    end.

configured_token() ->
    Configured = case application:get_env(mabelelink, api_token) of
                     {ok, AppToken} when is_binary(AppToken) -> AppToken;
                     _ ->
                         case os:getenv("MABELELINK_API_TOKEN") of
                             false -> undefined;
                             EnvToken -> unicode:characters_to_binary(EnvToken)
                         end
                 end,
    case Configured of
        Token when is_binary(Token), byte_size(Token) >= ?MIN_TOKEN_BYTES ->
            {ok, Token};
        _ -> {error, unconfigured}
    end.

secure_equal(Expected, Provided) when byte_size(Expected) =:= byte_size(Provided) ->
    secure_equal(Expected, Provided, 0) =:= 0;
secure_equal(_Expected, _Provided) ->
    false.

secure_equal(<<>>, <<>>, Difference) -> Difference;
secure_equal(<<Expected, ExpectedRest/binary>>,
             <<Provided, ProvidedRest/binary>>, Difference) ->
    secure_equal(ExpectedRest, ProvidedRest, Difference bor (Expected bxor Provided)).
