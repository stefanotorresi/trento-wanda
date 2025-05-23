defmodule Wanda.Operations.ServerTest do
  use Wanda.DataCase

  import Mox
  import Wanda.Factory

  alias Wanda.Operations.{Operation, Server}

  alias Wanda.Operations.Catalog.TestRegistry

  alias Trento.Operations.V1.{
    OperationCompleted,
    OperationStarted,
    OperatorExecutionRequested,
    OperatorExecutionRequestedTarget
  }

  require Wanda.Operations.Enums.Result, as: Result
  require Wanda.Operations.Enums.Status, as: Status
  require Wanda.Operations.Enums.OperatorPhase, as: OperatorPhase

  @existing_catalog_operation_id "testoperation@v1"

  setup [:set_mox_from_context, :verify_on_exit!]

  setup do
    Application.put_env(:wanda, :operations_registry, TestRegistry.test_registry())
    on_exit(fn -> Application.delete_env(:wanda, :operations_registry) end)

    {:ok, []}
  end

  describe "operation execution" do
    test "should not start operation if targets are missing" do
      catalog_operation = build(:catalog_operation)

      assert {:error, :targets_missing} =
               Server.start_operation(
                 UUID.uuid4(),
                 UUID.uuid4(),
                 catalog_operation,
                 [],
                 %{}
               )
    end

    test "should not start operation if required arguments on targets are missing" do
      catalog_operation = build(:catalog_operation, required_args: ["arg1", "arg2"])

      test_targets = [
        build_list(2, :operation_target),
        [
          build(:operation_target, arguments: %{"arg1" => "value"}),
          build(:operation_target, arguments: %{"arg2" => "value"})
        ],
        [
          build(:operation_target, arguments: %{"arg1" => "value", "arg2" => "value"}),
          build(:operation_target, arguments: %{"arg2" => "value"})
        ],
        [
          build(:operation_target, arguments: %{"arg1" => "value"}),
          build(:operation_target, arguments: %{"arg1" => "value", "arg2" => "value"})
        ]
      ]

      for targets <- test_targets do
        assert {:error, :arguments_missing} =
                 Server.start_operation(
                   UUID.uuid4(),
                   UUID.uuid4(),
                   catalog_operation,
                   targets,
                   %{}
                 )
      end
    end

    test "should not start operation if it is already running for that group_id" do
      group_id = UUID.uuid4()

      expect(Wanda.Messaging.Adapters.Mock, :publish, 3, fn
        _, "results", %OperationStarted{}, _ -> :ok
        _, "agents", %OperatorExecutionRequested{}, _ -> :ok
        _, "results", %OperationCompleted{result: :ABORTED}, _ -> :ok
      end)

      Server.start_operation(
        UUID.uuid4(),
        group_id,
        build(:catalog_operation, id: @existing_catalog_operation_id),
        build_list(2, :operation_target),
        []
      )

      pid = :global.whereis_name({Server, group_id})

      assert {:error, :already_running} =
               Server.start_operation(
                 UUID.uuid4(),
                 group_id,
                 build(:catalog_operation),
                 build_list(2, :operation_target),
                 []
               )

      GenServer.stop(pid)
    end

    test "should stop execution if last step failed" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()
      operation = build(:catalog_operation, id: @existing_catalog_operation_id)

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = build_list(2, :operation_target)

      expect(Wanda.Messaging.Adapters.Mock, :publish, 3, fn
        _, "results", %OperationStarted{}, _ ->
          :ok

        _,
        "agents",
        %OperatorExecutionRequested{
          targets: [
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_1},
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_2}
          ]
        },
        _ ->
          :ok

        _, "results", %OperationCompleted{result: :FAILED}, _ ->
          :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      %{diff: %{before: before, after: after_value}} =
        result_1 = build(:operator_result)

      %{message: message} = result_2 = build(:operator_error, phase: OperatorPhase.verify())

      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_1, result_1)
      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_2, result_2)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{result: Result.failed(), status: Status.completed(), agent_reports: agent_reports} =
        Repo.get(Operation, operation_id)

      expected_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "updated",
              diff: %{before: before, after: after_value},
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "failed",
              diff: nil,
              error_message: message
            }
          ]
        },
        %{
          step_number: 1,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "not_executed",
              diff: nil,
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_executed",
              diff: nil,
              error_message: nil
            }
          ]
        }
      ]

      assert expected_agent_reports == agent_reports
    end

    test "should complete execution when all steps are executed in the targets" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation =
        build(:catalog_operation,
          id: @existing_catalog_operation_id,
          steps: [
            %{operator: operator_1} = build(:operation_step, predicate: "*"),
            %{operator: operator_2} = build(:operation_step, predicate: "")
          ]
        )

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = build_list(2, :operation_target)

      expect(Wanda.Messaging.Adapters.Mock, :publish, 4, fn
        _, "results", %OperationStarted{}, _ ->
          :ok

        _,
        "agents",
        %OperatorExecutionRequested{
          operator: ^operator_1,
          targets: [
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_1},
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_2}
          ]
        },
        _ ->
          :ok

        _,
        "agents",
        %OperatorExecutionRequested{
          operator: ^operator_2,
          targets: [
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_1},
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_2}
          ]
        },
        _ ->
          :ok

        _, "results", %OperationCompleted{result: :UPDATED}, _ ->
          :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      # Getting the state of the GenServer make the test wait until the genserver has changed it
      # internal state. It is just a better way of waiting until the process moved on rather
      # than having a fixed sleep code
      :sys.get_state(pid)

      %{status: Status.running(), agent_reports: initial_agent_reports} =
        Repo.get(Operation, operation_id)

      expected_initial_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "not_executed",
              diff: nil,
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_executed",
              diff: nil,
              error_message: nil
            }
          ]
        },
        %{
          step_number: 1,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "not_executed",
              diff: nil,
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_executed",
              diff: nil,
              error_message: nil
            }
          ]
        }
      ]

      assert expected_initial_agent_reports == initial_agent_reports

      %{diff: %{before: before_1, after: after_1}} = result_1 = build(:operator_result)
      result_2 = build(:operator_result, %{diff: %{before: "foo", after: "foo"}})

      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_1, result_1)
      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_2, result_2)

      :sys.get_state(pid)

      %{status: Status.running(), agent_reports: agent_reports} =
        Repo.get(Operation, operation_id)

      expected_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "updated",
              diff: %{before: before_1, after: after_1},
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_updated",
              diff: %{before: "foo", after: "foo"},
              error_message: nil
            }
          ]
        },
        %{
          step_number: 1,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "not_executed",
              diff: nil,
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_executed",
              diff: nil,
              error_message: nil
            }
          ]
        }
      ]

      assert expected_agent_reports == agent_reports

      %{diff: %{before: before_3, after: after_3}} =
        result_3 = build(:operator_result, %{phase: OperatorPhase.verify()})

      %{diff: %{before: before_4, after: after_4}} =
        result_4 = build(:operator_result, %{phase: OperatorPhase.verify()})

      Server.receive_operation_reports(operation_id, group_id, 1, agent_id_1, result_3)
      Server.receive_operation_reports(operation_id, group_id, 1, agent_id_2, result_4)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{result: Result.updated(), status: Status.completed(), agent_reports: final_agent_reports} =
        Repo.get(Operation, operation_id)

      expected_final_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "updated",
              diff: %{before: before_1, after: after_1},
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_updated",
              diff: %{before: "foo", after: "foo"},
              error_message: nil
            }
          ]
        },
        %{
          step_number: 1,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "updated",
              diff: %{before: before_3, after: after_3},
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "updated",
              diff: %{before: before_4, after: after_4},
              error_message: nil
            }
          ]
        }
      ]

      assert expected_final_agent_reports == final_agent_reports
    end

    test "should skip operation in agent if predicate is false" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation =
        build(:catalog_operation,
          id: @existing_catalog_operation_id,
          steps: build_list(1, :operation_step, predicate: "value == 5")
        )

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = [
          build(:operation_target, arguments: %{"value" => 5}),
          build(:operation_target, arguments: %{"value" => 10})
        ]

      expect(Wanda.Messaging.Adapters.Mock, :publish, 3, fn
        _, "results", %OperationStarted{}, _ ->
          :ok

        _,
        "agents",
        %OperatorExecutionRequested{
          targets: [
            %OperatorExecutionRequestedTarget{agent_id: ^agent_id_1}
          ]
        },
        _ ->
          :ok

        _, "results", %OperationCompleted{result: :UPDATED}, _ ->
          :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      %{diff: %{before: before_1, after: after_1}} =
        result_1 = build(:operator_result, phase: OperatorPhase.verify())

      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_1, result_1)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{result: Result.updated(), status: Status.completed(), agent_reports: agent_reports} =
        Repo.get(Operation, operation_id)

      expected_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "updated",
              diff: %{before: before_1, after: after_1},
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "skipped",
              diff: nil,
              error_message: nil
            }
          ]
        }
      ]

      assert expected_agent_reports == agent_reports
    end

    test "should move to the next step if the predicate is false in all agents" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation =
        build(:catalog_operation,
          id: @existing_catalog_operation_id,
          steps: build_list(1, :operation_step, predicate: "value == 5")
        )

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = [
          build(:operation_target, arguments: %{"value" => 10}),
          build(:operation_target, arguments: %{"value" => 10})
        ]

      expect(Wanda.Messaging.Adapters.Mock, :publish, 2, fn
        _, "results", %OperationStarted{}, _ -> :ok
        _, "results", %OperationCompleted{result: :NOT_UPDATED}, _ -> :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{result: Result.skipped(), status: Status.completed(), agent_reports: agent_reports} =
        Repo.get(Operation, operation_id)

      expected_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "skipped",
              diff: nil,
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "skipped",
              diff: nil,
              error_message: nil
            }
          ]
        }
      ]

      assert expected_agent_reports == agent_reports
    end

    test "should ignore unrecognized operation and step reports" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation = build(:catalog_operation, id: @existing_catalog_operation_id)

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = build_list(2, :operation_target)

      expect(Wanda.Messaging.Adapters.Mock, :publish, 3, fn
        _, "results", %OperationStarted{}, _ -> :ok
        _, "agents", %OperatorExecutionRequested{}, _ -> :ok
        _, "results", %OperationCompleted{result: :ABORTED}, _ -> :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      :sys.get_state(pid)

      operation_state = Repo.get(Operation, operation_id)

      Server.receive_operation_reports(
        UUID.uuid4(),
        group_id,
        0,
        agent_id_1,
        build(:operator_result)
      )

      Server.receive_operation_reports(
        operation_id,
        group_id,
        1,
        agent_id_2,
        build(:operator_result)
      )

      :sys.get_state(pid)

      assert operation_state == Repo.get(Operation, operation_id)

      GenServer.stop(pid)
    end

    test "should timeout a step execution and set the operation as failed" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation =
        build(:catalog_operation,
          id: @existing_catalog_operation_id,
          steps: build_list(2, :operation_step, timeout: 0)
        )

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = build_list(2, :operation_target)

      expect(Wanda.Messaging.Adapters.Mock, :publish, 3, fn
        _, "results", %OperationStarted{}, _ ->
          :ok

        _, "agents", %OperatorExecutionRequested{}, [expiration: expiration] ->
          assert 0 == DateTime.diff(DateTime.utc_now(), expiration)
          :ok

        _, "results", %OperationCompleted{result: :FAILED}, _ ->
          :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{result: Result.timeout(), status: Status.completed(), agent_reports: agent_reports} =
        Repo.get(Operation, operation_id)

      expected_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "timeout",
              diff: nil,
              error_message: "Operator execution timed out"
            },
            %{
              agent_id: agent_id_2,
              result: "timeout",
              diff: nil,
              error_message: "Operator execution timed out"
            }
          ]
        },
        %{
          step_number: 1,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "not_executed",
              diff: nil,
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "not_executed",
              diff: nil,
              error_message: nil
            }
          ]
        }
      ]

      assert expected_agent_reports == agent_reports
    end

    test "should restart the timeout timer when a step is completed" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation =
        build(:catalog_operation,
          id: @existing_catalog_operation_id,
          steps: [
            build(:operation_step, timeout: 10_000),
            build(:operation_step, timeout: 0)
          ]
        )

      [%{agent_id: agent_id_1}, %{agent_id: agent_id_2}] =
        targets = build_list(2, :operation_target)

      Wanda.Messaging.Adapters.Mock
      |> expect(:publish, 1, fn
        _, "results", %OperationStarted{}, _ -> :ok
      end)
      |> expect(:publish, 1, fn
        _, "agents", %OperatorExecutionRequested{}, [expiration: expiration] ->
          assert 0 ==
                   DateTime.diff(
                     DateTime.add(DateTime.utc_now(), 10_000, :millisecond),
                     expiration
                   )

          :ok
      end)
      |> expect(:publish, 1, fn
        _, "agents", %OperatorExecutionRequested{}, [expiration: expiration] ->
          assert 0 == DateTime.diff(DateTime.utc_now(), expiration)

          :ok
      end)
      |> expect(:publish, 1, fn
        _, "results", %OperationCompleted{result: :FAILED}, _ -> :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      %{diff: %{before: before_1, after: after_1}} =
        result_1 = build(:operator_result)

      %{diff: %{before: before_2, after: after_2}} =
        result_2 = build(:operator_result)

      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_1, result_1)
      Server.receive_operation_reports(operation_id, group_id, 0, agent_id_2, result_2)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{result: Result.timeout(), status: Status.completed(), agent_reports: agent_reports} =
        Repo.get(Operation, operation_id)

      expected_agent_reports = [
        %{
          step_number: 0,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "updated",
              diff: %{before: before_1, after: after_1},
              error_message: nil
            },
            %{
              agent_id: agent_id_2,
              result: "updated",
              diff: %{before: before_2, after: after_2},
              error_message: nil
            }
          ]
        },
        %{
          step_number: 1,
          agents: [
            %{
              agent_id: agent_id_1,
              result: "timeout",
              diff: nil,
              error_message: "Operator execution timed out"
            },
            %{
              agent_id: agent_id_2,
              result: "timeout",
              diff: nil,
              error_message: "Operator execution timed out"
            }
          ]
        }
      ]

      assert expected_agent_reports == agent_reports
    end

    test "should abort the operation when the server is stopped from external signal" do
      operation_id = UUID.uuid4()
      group_id = UUID.uuid4()

      operation =
        build(:catalog_operation, id: @existing_catalog_operation_id)

      targets = build_list(2, :operation_target)

      expect(Wanda.Messaging.Adapters.Mock, :publish, 3, fn
        _, "results", %OperationStarted{}, _ -> :ok
        _, "agents", %OperatorExecutionRequested{}, _ -> :ok
        _, "results", %OperationCompleted{result: :ABORTED}, _ -> :ok
      end)

      Server.start_operation(
        operation_id,
        group_id,
        operation,
        targets,
        []
      )

      pid = :global.whereis_name({Server, group_id})
      ref = Process.monitor(pid)

      GenServer.stop(pid)

      assert_receive {:DOWN, ^ref, _, ^pid, :normal}, 500

      %{status: Status.aborted()} = Repo.get(Operation, operation_id)
    end
  end
end
