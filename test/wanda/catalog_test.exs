defmodule Wanda.CatalogTest do
  use Wanda.DataCase, async: true

  import Wanda.Factory

  alias Wanda.Catalog

  alias Wanda.Catalog.{
    Check,
    Condition,
    Expectation,
    Fact,
    SelectableCheck,
    SelectedCheck,
    Value
  }

  def all_files do
    configured_paths = Application.fetch_env!(:wanda, Wanda.Catalog)[:catalog_paths]

    Enum.flat_map(configured_paths, fn path ->
      path
      |> File.ls!()
      |> Enum.sort()
    end)
  end

  describe "checks catalog" do
    test "should return the whole catalog taking into account different paths" do
      valid_files =
        Enum.filter(all_files(), fn file ->
          file != "malformed_check.yaml" and file != "malformed_file.yaml"
        end)

      catalog = Catalog.get_catalog()
      assert length(valid_files) == length(catalog)

      Enum.with_index(catalog, fn check, index ->
        file_name =
          valid_files
          |> Enum.at(index)
          |> Path.basename(".yaml")

        assert %Check{id: ^file_name} = check
      end)
    end

    test "should read the whole catalog and throw no errors with malformed files" do
      catalog = Catalog.get_catalog()

      assert length(all_files()) == length(catalog) + 2
    end

    test "should filter out checks if the when clause doesn't match" do
      complete_catalog = Catalog.get_catalog(%{"provider" => "azure"})
      catalog = Catalog.get_catalog(%{"provider" => "aws"})

      assert length(complete_catalog) - 1 == length(catalog)

      refute Enum.any?(catalog, fn %Check{id: id} -> id == "when_condition_check" end)
    end

    test "should filter out checks if the metadata doesn't match" do
      complete_catalog = Catalog.get_catalog(%{"some" => "kind"})
      catalog = Catalog.get_catalog(%{"some" => "wanda"})

      assert length(complete_catalog) - 1 == length(catalog)

      refute Enum.any?(catalog, fn %Check{id: id} -> id == "with_metadata" end)
    end

    test "should match metadata when value is in a list" do
      complete_catalog = Catalog.get_catalog(%{"some" => "kind"})
      catalog = Catalog.get_catalog(%{"list" => "this"})

      assert length(complete_catalog) == length(catalog)

      assert Enum.any?(catalog, fn %Check{id: id} -> id == "with_metadata" end)
    end

    test "should not filter out checks if the provided env includes just different keys" do
      complete_catalog = Catalog.get_catalog(%{"some" => "kind"})
      catalog = Catalog.get_catalog(%{"wow" => "carbonara"})

      assert length(complete_catalog) == length(catalog)

      assert Enum.any?(catalog, fn %Check{id: id} -> id == "with_metadata" end)
    end

    test "should load a check from a yaml file properly" do
      assert {:ok,
              %Check{
                id: "expect_check",
                name: "Test check",
                group: "Test",
                description: "Just a check\n",
                remediation: "## Remediation\nRemediation text\n",
                severity: :critical,
                facts: [
                  %Fact{
                    name: "jedi",
                    gatherer: "wandalorian",
                    argument: "-o"
                  },
                  %Fact{
                    name: "other_fact",
                    gatherer: "no_args_gatherer",
                    argument: ""
                  }
                ],
                values: [
                  %Value{
                    conditions: [
                      %Condition{expression: "some_expression", value: 10},
                      %Condition{expression: "some_other_expression", value: 15}
                    ],
                    default: 5,
                    name: "expected_value"
                  },
                  %Value{
                    conditions: [
                      %Condition{expression: "some_third_expression", value: 5}
                    ],
                    default: 10,
                    name: "expected_higher_value"
                  }
                ],
                expectations: [
                  %Expectation{
                    name: "some_expectation",
                    type: :expect,
                    expression: "facts.jedi == values.expected_value",
                    failure_message: "some failure message ${facts.jedi}"
                  },
                  %Expectation{
                    name: "some_other_expectation",
                    type: :expect,
                    expression: "facts.jedi > values.expected_higher_value",
                    failure_message: nil
                  }
                ]
              }} = Catalog.get_check("expect_check")
    end

    test "should load a expect_same expectation type" do
      assert {:ok,
              %Check{
                values: [],
                expectations: [
                  %Expectation{
                    name: "some_expectation",
                    type: :expect_same,
                    expression: "facts.jedi"
                  }
                ]
              }} = Catalog.get_check("expect_same_check")
    end

    test "should load a expect_enum expectation type" do
      assert {:ok,
              %Check{
                values: [
                  %Value{
                    default: 5,
                    name: "expected_passing_value"
                  },
                  %Value{
                    default: 3,
                    name: "expected_warning_value"
                  }
                ],
                expectations: [
                  %Expectation{
                    name: "some_expectation",
                    type: :expect_enum,
                    expression: """
                    if facts.jedi == values.expected_passing_value {
                      "passing"
                    } else if facts.jedi == values.expected_warning_value {
                      "warning"
                    } else {
                      "critical"
                    }
                    """,
                    failure_message: "some failure message ${facts.jedi}",
                    warning_message: "some warning message ${facts.jedi}"
                  }
                ]
              }} = Catalog.get_check("expect_enum_check")
    end

    test "should load a warning severity" do
      assert {:ok, %Check{severity: :warning}} =
               Catalog.get_check("warning_severity_check")
    end

    test "should return an error for non-existent check" do
      assert {:error, _} = Catalog.get_check("non_existent_check")
    end

    test "should return an error for malformed check" do
      assert {:error, :malformed_check} = Catalog.get_check("malformed_check")
    end

    test "should load multiple checks" do
      assert [%Check{id: "expect_check"}, %Check{id: "expect_same_check"}] =
               Catalog.get_checks(
                 ["expect_check", "non_existent_check", "expect_same_check"],
                 %{}
               )
    end

    test "should allow opting out a check's customizability" do
      assert {:ok, %Check{customization_disabled: true}} =
               Catalog.get_check("non_customizable_check")
    end

    test "should expose customizability opt-out flags as defined in check's spec" do
      assert {:ok,
              %Check{
                customization_disabled: false,
                values: [
                  %Value{name: "numeric_value", customization_disabled: false},
                  %Value{name: "customizable_string_value", customization_disabled: false},
                  %Value{name: "non_customizable_string_value", customization_disabled: true},
                  %Value{name: "bool_value", customization_disabled: false},
                  %Value{name: "list_value", customization_disabled: false},
                  %Value{name: "map_value", customization_disabled: true}
                ]
              }} = Catalog.get_check("mixed_values_customizability")
    end
  end

  describe "group scoped catalog" do
    test "should return group related catalog when no values were customized" do
      selectable_checks =
        Catalog.get_catalog_for_group(Faker.UUID.v4(), %{
          "id" => "mixed_values_customizability"
        })

      assert length(selectable_checks) == 10

      refute Enum.any?(selectable_checks, & &1.customized)

      selectable_checks
      |> Enum.flat_map(& &1.values)
      |> Enum.each(&assert_non_customized_value/1)
    end

    test "should return group related catalog with proper custom values" do
      customized_check_id = "mixed_values_customizability"

      scenarios = [
        %{
          group_id: Faker.UUID.v4(),
          numeric_value: 420,
          expected_customization: 420
        },
        %{
          group_id: Faker.UUID.v4(),
          numeric_value: 420.1,
          expected_customization: 420.1
        }
      ]

      for %{
            group_id: group_id,
            numeric_value: numeric_value,
            expected_customization: expected_customization
          } <- scenarios do
        insert(:check_customization,
          group_id: group_id,
          check_id: customized_check_id,
          custom_values: [
            %{
              name: "numeric_value",
              value: numeric_value
            },
            %{
              name: "customizable_string_value",
              value: "new value"
            }
          ]
        )

        expected_customizations = [
          %{
            name: "numeric_value",
            customizable: true,
            default_value: 5,
            custom_value: expected_customization
          },
          %{
            name: "customizable_string_value",
            customizable: true,
            # default_value: "foo_bar", <- "foo_bar" is the default default_value
            # "baz_qux" is the env based resolved default_value
            default_value: "baz_qux",
            custom_value: "new value"
          },
          %{
            name: "non_customizable_string_value",
            customizable: false
          },
          %{
            name: "bool_value",
            customizable: true,
            default_value: true
          },
          %{
            name: "list_value",
            customizable: false
          },
          %{
            name: "map_value",
            customizable: false
          }
        ]

        selectable_checks =
          Catalog.get_catalog_for_group(group_id, %{
            "id" => "mixed_values_customizability",
            "some_key" => "some_value"
          })

        assert length(selectable_checks) == 10

        Enum.each(
          selectable_checks,
          fn
            %SelectableCheck{id: ^customized_check_id, values: values, customized: customized} ->
              assert ^expected_customizations = values
              assert customized

            %SelectableCheck{values: values, customized: customized} ->
              refute customized
              Enum.each(values, &assert_non_customized_value/1)
          end
        )
      end
    end

    test "should ignore non existing checks or checks values" do
      group_id = Faker.UUID.v4()
      customized_check_id = "mixed_values_customizability"
      non_existing_check_id = "non_existing_check"

      insert(:check_customization,
        group_id: group_id,
        check_id: customized_check_id,
        custom_values: [
          %{
            name: "customizable_string_value",
            value: "new value"
          },
          %{
            name: "non_existing_value",
            value: "new value"
          }
        ]
      )

      insert(:check_customization,
        group_id: group_id,
        check_id: non_existing_check_id
      )

      selectable_checks =
        Catalog.get_catalog_for_group(group_id, %{
          "id" => "mixed_values_customizability"
        })

      refute Enum.any?(selectable_checks, &(&1.id == non_existing_check_id))

      refute selectable_checks
             |> Enum.find(&(&1.id == customized_check_id))
             |> Map.get(:values)
             |> Enum.any?(&(&1.name == "non_existing_value"))
    end

    test "should properly compute customizability information" do
      selectable_checks =
        Catalog.get_catalog_for_group(Faker.UUID.v4(), %{
          "id" => "mixed_values_customizability"
        })

      find_check = fn id ->
        Enum.find(selectable_checks, fn %SelectableCheck{id: check_id} ->
          id == check_id
        end)
      end

      assert %SelectableCheck{customizable: false, values: forcedly_non_customizable_values} =
               find_check.("non_customizable_check")

      assert Enum.all?(forcedly_non_customizable_values, fn %{customizable: customizable} ->
               not customizable
             end)

      assert %SelectableCheck{customizable: false, values: []} =
               find_check.("check_without_values")

      assert %SelectableCheck{customizable: false, values: explicit_non_customizable_check_values} =
               find_check.("non_customizable_check_values")

      assert Enum.all?(explicit_non_customizable_check_values, fn %{customizable: customizable} ->
               not customizable
             end)

      assert %SelectableCheck{
               customizable: true,
               values: [
                 %{name: "expected_value", customizable: true},
                 %{name: "expected_higher_value", customizable: false}
               ]
             } = find_check.("customizable_check")

      assert %SelectableCheck{
               customizable: true,
               values: [
                 %{name: "numeric_value", customizable: true},
                 %{name: "customizable_string_value", customizable: true},
                 %{name: "non_customizable_string_value", customizable: false},
                 %{name: "bool_value", customizable: true},
                 %{name: "list_value", customizable: false},
                 %{name: "map_value", customizable: false}
               ]
             } = find_check.("mixed_values_customizability")
    end

    defp assert_non_customized_value(%{name: _, customizable: customizable} = value) do
      refute Map.has_key?(value, :custom_value)

      if not customizable do
        refute Map.has_key?(value, :default_value)
      end
    end
  end

  describe "checks execution selection" do
    test "should return an empty list" do
      assert [] == Catalog.to_selected_checks([], Faker.UUID.v4())
    end

    test "should return current selection with no customized checks" do
      %Check{id: check_id_1} = check1 = build(:check)
      %Check{id: check_id_2} = check2 = build(:check)

      assert [
               %SelectedCheck{
                 id: ^check_id_1,
                 spec: ^check1,
                 customized: false,
                 customizations: []
               },
               %SelectedCheck{
                 id: ^check_id_2,
                 spec: ^check2,
                 customized: false,
                 customizations: []
               }
             ] = Catalog.to_selected_checks([check1, check2], Faker.UUID.v4())
    end

    test "should return current selection with some customized checks" do
      group_id = Faker.UUID.v4()
      custom_numeric_value = 420

      %Check{id: check_id_1} = check1 = build(:check)
      %Check{id: check_id_2} = check2 = build(:check)

      %Check{id: check_id_3} =
        check3 =
        build(:check,
          values: [
            %{
              name: "numeric_value",
              value: 12
            }
          ]
        )

      insert(:check_customization,
        group_id: group_id,
        check_id: check_id_3,
        custom_values: [
          %{
            name: "numeric_value",
            value: custom_numeric_value
          }
        ]
      )

      assert [
               %SelectedCheck{
                 id: ^check_id_1,
                 spec: ^check1,
                 customized: false,
                 customizations: []
               },
               %SelectedCheck{
                 id: ^check_id_2,
                 spec: ^check2,
                 customized: false,
                 customizations: []
               },
               %SelectedCheck{
                 id: ^check_id_3,
                 spec: ^check3,
                 customized: true,
                 customizations: [
                   %{
                     name: "numeric_value",
                     value: ^custom_numeric_value
                   }
                 ]
               }
             ] = Catalog.to_selected_checks([check1, check2, check3], group_id)
    end
  end
end
