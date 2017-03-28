%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2016 Pivotal Software, Inc.  All rights reserved.
%%
-module(rabbitmqctl_stop_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-compile(export_all).

all() ->
    [
        {group, stop_running_node} %,
        % {group, stop_not_running_node}
    ].

groups() ->
    StopTests = [
        stop_exits_on_missing_pidfile,
        stop_exits_on_unreadable_pidfile,
        stop_exits_on_malformed_pidfile,
        stop_exits_on_non_running_process_pidfile,
        stop_exits_on_non_erlang_vm_pidfile,
        stop_exits_on_non_node_pidfile
    ],
    [
        {stop_running_node, [], StopTests ++ [stop_running_node_ok]},
        {stop_not_running_node, [], StopTests}
    ].

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(stop_running_node, Config) ->
    rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, ?MODULE},
        {need_start, true}
    ]);
init_per_group(stop_not_running_node, Config) ->
    rabbit_ct_helpers:set_config(Config, [
        {rmq_nodename_suffix, ?MODULE}
    ]).

end_per_group(stop_running_node, Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config, []);
end_per_group(stop_not_running_node, Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config, []).

init_per_testcase(Testcase = stop_exits_on_non_node_pidfile, Config0) ->
    Config1 = case ?config(need_start, Config0) of
        true ->
            rabbit_ct_helpers:run_setup_steps(
                rabbit_ct_helpers:set_config(Config0, [{rmq_nodes_count, 2}]),
                rabbit_ct_broker_helpers:setup_steps() ++
                [fun save_node/1,
                 fun save_other_node_pid/1]);
        _ ->
            rabbit_ct_helpers:run_setup_steps(
                rabbit_ct_helpers:set_config(Config0,
                    [{node, non_existent_node@localhost}]),
                rabbit_ct_broker_helpers:setup_steps() ++
                [fun save_node_pid/1])
    end,
    rabbit_ct_helpers:testcase_started(Config1, Testcase);
init_per_testcase(Testcase, Config0) ->
    Config1 = case ?config(need_start, Config0) of
        true ->
            rabbit_ct_helpers:run_setup_steps(Config0,
                rabbit_ct_broker_helpers:setup_steps() ++
                [fun save_node/1]);
        _ ->
            rabbit_ct_helpers:set_config(Config0,
                [{node, non_existent_node@localhost}])
    end,
    rabbit_ct_helpers:testcase_started(Config1, Testcase).

end_per_testcase(Testcase = stop_exits_on_non_node_pidfile, Config0) ->
    Config1 = case ?config(need_start, Config0) of
        true ->
            rabbit_ct_helpers:run_teardown_steps(Config0,
                rabbit_ct_broker_helpers:teardown_steps());
        _ -> rabbit_ct_helpers:run_teardown_steps(Config0,
                rabbit_ct_broker_helpers:teardown_steps())
    end,
    rabbit_ct_helpers:testcase_finished(Config1, Testcase);
end_per_testcase(Testcase, Config0) ->
    Config1 = case ?config(need_start, Config0) of
        true ->
            rabbit_ct_helpers:run_teardown_steps(Config0,
                rabbit_ct_broker_helpers:teardown_steps());
        _ -> Config0
    end,
    rabbit_ct_helpers:testcase_finished(Config1, Testcase).

save_node(Config) ->
    Node = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    rabbit_ct_helpers:set_config(Config, [{node, Node}]).

save_node_pid(Config) ->
    save_node_pid(Config, 0).

save_other_node_pid(Config) ->
    save_node_pid(Config, 1).

save_node_pid(Config, N) ->
    Node0 = rabbit_ct_broker_helpers:get_node_config(Config, N, nodename),
    Node0PidStr = rpc:call(Node0, os, getpid, []),
    true = is_list(Node0PidStr),
    Node0Pid = list_to_integer(Node0PidStr),
    rabbit_ct_helpers:set_config(Config, [{other_node_pid, Node0Pid}]).

stop_exits_on_missing_pidfile(Config) ->
    PidFile = "/path/to/non_existent_file",
    Node = ?config(node, Config),
    NodeState = node_is_running(Node),
    try rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2) of
        _ -> error(expected_to_fail)
    catch
        _Type:{error, {could_not_read_pid,{error,enoent}}} ->
            NodeState = node_is_running(Node),
            ok;
        _Type:Err ->
            error({expecting_different_error, Err})
    end.

stop_exits_on_unreadable_pidfile(Config) ->
    DataDir = ?config(data_dir, Config),
    PidFile = filename:join(DataDir, "unreadable"),
    file:delete(PidFile),
    ok = file:write_file(PidFile, <<"">>),
    ok = file:change_mode(PidFile, 8#00000),
    Node = ?config(node, Config),
    NodeState = node_is_running(Node),
    try rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2) of
        Result -> error({expected_to_fail, Result})
    catch
        _Type:{error, {could_not_read_pid,{error,eacces}}} ->
            NodeState = node_is_running(Node),
            ok;
        _Type:Err ->
            error({expecting_different_error, Err})
    end.

stop_exits_on_malformed_pidfile(Config) ->
    DataDir = ?config(data_dir, Config),
    PidFile = filename:join(DataDir, "not_pid"),
    file:delete(PidFile),
    ok = file:write_file(PidFile, <<"i am not pid">>),
    Node = ?config(node, Config),
    NodeState = node_is_running(Node),
    try rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2) of
        Result -> error({expected_to_fail, Result})
    catch
        _Type:{error,{garbage_in_pid_file,_}} ->
            NodeState = node_is_running(Node),
            ok;
        _Type:Err ->
            error({expecting_different_error, Err})
    end.

stop_exits_on_non_running_process_pidfile(Config) ->
    DataDir = ?config(data_dir, Config),
    PidFile = filename:join(DataDir, "not_pid"),
    file:delete(PidFile),
    Pid = non_existent_proc_pid(),
    false = pid_alive(Pid),
    ok = file:write_file(PidFile, integer_to_binary(Pid)),
    Node = ?config(node, Config),
    NodeState = node_is_running(Node),
    try rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2) of
        Result -> error({expected_to_fail, Result})
    catch
        _Type:{error,{pid_is_not_running,_}} ->
            NodeState = node_is_running(Node),
            ok;
        _Type:Err ->
            error({expecting_different_error, Err})
    end.

stop_exits_on_non_erlang_vm_pidfile(Config) ->
    DataDir = ?config(data_dir, Config),
    PidFile = filename:join(DataDir, "not_pid"),
    file:delete(PidFile),
    Pid = existent_proc_pid(),
    ok = file:write_file(PidFile, integer_to_binary(Pid)),
    Node = ?config(node, Config),
    NodeState = node_is_running(Node),
    try rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2) of
        Result -> error({expected_to_fail, Result})
    catch
        _Type:{error,{not_a_node_pid,_}} ->
            NodeState = node_is_running(Node),
            ok;
        _Type:Err ->
            error({expecting_different_error, Err})
    end.

stop_exits_on_non_node_pidfile() -> [{timetrap, 20000}].

stop_exits_on_non_node_pidfile(Config) ->
    DataDir = ?config(data_dir, Config),
    PidFile = filename:join(DataDir, "other_node_pid"),
    file:delete(PidFile),
    Pid = ?config(other_node_pid, Config),
    ok = file:write_file(PidFile, integer_to_binary(Pid)),
    Node = ?config(node, Config),
    NodeState = node_is_running(Node),
    try rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2) of
        Result -> error({expected_to_fail, Result})
    catch
        _Type:{error,{wrong_node_pid,_}} ->
            NodeState = node_is_running(Node),
            ok;
        _Type:Err ->
            error({expecting_different_error, Err})
    end.

stop_running_node_ok(Config) ->
    DataDir = ?config(data_dir, Config),
    PidFile = filename:join(DataDir, "node_pid"),
    file:delete(PidFile),
    Node = ?config(node, Config),
    Pid = node_pid(Node),
    ok = file:write_file(PidFile, integer_to_binary(Pid)),
    ok = rabbit_control_main:action(stop, Node, [PidFile], [], fun ct:pal/2),
    false = erlang_pid_is_running(Pid),
    false = node_is_running(Node).

node_pid(Node) ->
    Val = rpc:call(Node, os, getpid, []),
    true = is_list(Val),
    list_to_integer(Val).

erlang_pid_is_running(Pid) ->
    rabbit_misc:is_os_process_alive(integer_to_list(Pid)).

node_is_running(Node) ->
    net_adm:ping(Node) == pong.

existent_proc_pid() ->
    Port = open_port({spawn, "sleep 10"}, []),
    Info = erlang:port_info(Port),
    OsPid = proplists:get_value(os_pid, Info),
    true = is_integer(OsPid),
    OsPid.

non_existent_proc_pid() ->
    Port = open_port({spawn, "sleep 2"}, []),
    Info = erlang:port_info(Port),
    OsPid = proplists:get_value(os_pid, Info),
    true = is_integer(OsPid),
    port_close(Port),
    undefined = erlang:port_info(Port),
    wait_for_process_stop(OsPid),
    OsPid.

wait_for_process_stop(Pid) ->
    case pid_alive(Pid) of
        true  -> ct:sleep(20), wait_for_process_stop(Pid);
        false -> ok
    end.

pid_alive(Pid) ->
    [] =/= os:cmd("ps -o pid= " ++ integer_to_list(Pid)).

