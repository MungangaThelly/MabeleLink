-module(mabelelink_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Listings = #{id => mabelelink_listings,
                 start => {mabelelink_listings, start_link, []},
                 restart => permanent,
                 shutdown => 5000,
                 type => worker,
                 modules => [mabelelink_listings]},
    Http = #{id => mabelelink_http,
             start => {mabelelink_http, start_link, []},
             restart => permanent,
             shutdown => 5000,
             type => worker,
             modules => [mabelelink_http]},
    {ok, {{one_for_one, 5, 10}, [Listings, Http]}}.
