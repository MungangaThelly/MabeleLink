-module(mabelelink_http).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(LISTENER, mabelelink_http_listener).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    Port = case application:get_env(mabelelink, http_port) of
               {ok, ConfiguredPort} -> ConfiguredPort;
               undefined -> 8080
           end,
    Routes = [{'_', [
        {"/", cowboy_static, {priv_file, mabelelink, "index.html"}},
        {"/favicon.svg", cowboy_static, {priv_file, mabelelink, "favicon.svg"}},
        {"/healthz", mabelelink_http_handler, health},
        {"/api/v1/listings", mabelelink_http_handler, listings},
        {"/api/v1/listings/:id", mabelelink_http_handler, listing},
        {"/api/v1/listings/:id/reservations", mabelelink_http_handler, reservation}
    ]}],
    Dispatch = cowboy_router:compile(Routes),
    case cowboy:start_clear(?LISTENER, [{port, Port}],
                            #{env => #{dispatch => Dispatch}}) of
        {ok, ListenerPid} -> {ok, #{listener => ListenerPid}};
        {error, Reason} -> {stop, {http_listener_start_failed, Reason}}
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported_request}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'EXIT', ListenerPid, Reason}, #{listener := ListenerPid} = State) ->
    {stop, {http_listener_exit, Reason}, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    cowboy:stop_listener(?LISTENER),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
