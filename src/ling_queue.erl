-module(ling_queue).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

-export([add/1]).
-export([start_build/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

add(Files) ->
	gen_server:call(?SERVER, {add,Files}).

start_build(ProjName, LingOpts) ->
	gen_server:call(?SERVER, {start_build,ProjName,LingOpts}, infinity).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(_Args) ->
	{ok, []}.

handle_call({add,More}, _From, Files) ->
    {reply, ok, More ++ Files};

handle_call({start_build,ProjName,LingOpts}, _From, Files) ->

	case check_opts(LingOpts) of
	{ConnOpts,BuildOpts} ->
		start_build(ProjName, Files, ConnOpts, BuildOpts);
	Error ->
		{reply,{error,Error},[]}
	end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

check_opts(Opts) ->
	check_opts(Opts, [], []).

check_opts([], ConnOpts, BuildOpts) ->
	{ConnOpts,BuildOpts};
check_opts([{build_host,Host} =Opt|Opts], ConnOpts, BuildOpts)
		when is_list(Host) ->
	check_opts(Opts, [Opt|ConnOpts], BuildOpts);
check_opts([{username,Name} =Opt|Opts], ConnOpts, BuildOpts)
		when is_list(Name) ->
	check_opts(Opts, [Opt|ConnOpts], BuildOpts);
check_opts([{password,Pwd} =Opt|Opts], ConnOpts, BuildOpts)
		when is_list(Pwd) ->
	check_opts(Opts, [Opt|ConnOpts], BuildOpts);
check_opts([{import,_}|Opts], ConnOpts, BuildOpts) ->
	%% ignore the options -- handled elsewhere
	check_opts(Opts, ConnOpts, BuildOpts);
check_opts([{import_lib,Lib} =Opt|Opts], ConnOpts, BuildOpts)
		when is_atom(Lib) ->
	check_opts(Opts, ConnOpts, [Opt|BuildOpts]);
check_opts([{image_type,Type} =Opt|Opts], ConnOpts, BuildOpts)
		when is_atom(Type) ->
	check_opts(Opts, ConnOpts, [Opt|BuildOpts]);
check_opts([{build_config,Cfg} =Opt|Opts], ConnOpts, BuildOpts)
		when is_atom(Cfg) ->
	check_opts(Opts, ConnOpts, [Opt|BuildOpts]);
check_opts([{strip_image,Flag} =Opt|Opts], ConnOpts, BuildOpts)
		when is_boolean(Flag) ->
	check_opts(Opts, ConnOpts, [Opt|BuildOpts]).

start_build(ProjName, Files, ConnOpts, BuildOpts) ->

	rebar_log:log(info, "starting inets~n", []),
	application:start(crypto),
	application:start(asn1),
	application:start(public_key),
	application:start(ssl),
	application:start(inets),

	{ok,Cwd} = file:get_cwd(),
	RelFiles = [relativise(F, Cwd) || F <- Files],

	rebar_log:log(info, "compressing ~w file(s): ~p~n",
							[length(RelFiles),RelFiles]),
	{ok,{_,ZipData}} = zip:zip("tmptmp.zip", RelFiles, [memory]),

	rebar_log:log(info, "uploading the project archive [~w byte(s)]~n",
							[size(ZipData)]),
 	ok = build_service:call(put, "/projects/" ++ ProjName, [],
							{"application/zip",ZipData}, ConnOpts),
	rebar_log:log(info, "project archive uploaded~n", []),

	ReqBody = build_request_body(BuildOpts),

	rebar_log:log(info, "build started for '~s'~n", [ProjName]),
	{ok,Banner} = build_service:call(post, "/build/" ++ ProjName, [],
							{"application/json",ReqBody}, ConnOpts),
	io:format("LBS: ~s~n", [Banner]),
	
	{reply,ok,[]}.

build_request_body(BuildOpts) ->
	Apps = [App || {_,App} <- lists:filter(fun({import_lib,_}) -> true;
					(_) -> false end, BuildOpts)],
	ImgType = proplists:get_value(image_type, BuildOpts),
	BuildConfig = proplists:get_value(build_config, BuildOpts, default),
	StripImage = proplists:get_value(strip_image, BuildOpts, false),
	Json = {struct,[
		{import_lib,
			[erlang:atom_to_binary(A, utf8) || A <- Apps]},
		{image_type,
			erlang:atom_to_binary(ImgType, utf8)},
		{build_config,
			config_number(BuildConfig)},
		{strip_image,
			StripImage}
	]},
	list_to_binary(mochijson2:encode(Json)).

config_number(default) -> 0;
config_number(fastest) -> 0;
config_number(debug) -> 1.

relativise(File, Cwd) ->
	case lists:prefix(Cwd, File) of
	true ->
		lists:nthtail(length(Cwd) +1, File)
	end.

%%EOF
