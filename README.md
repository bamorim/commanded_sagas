# CommandedSagas

> NOTE: This is still a work in progress.
> This is a draft based on the idea of README-driven-development

Commanded Sagas provides a macro for defining Commanded's aggregate as a Saga Log.
The idea is that the aggregate controls the state of the Saga and allow for async completion
of each saga subtransaction.

## Usage Example

Let's say we are building a eCommerce that has a cart and at somepoint we can checkout that
cart and the process involves three steps

### Defining the saga

```elixir
defmodule CheckoutSaga do
  use CommandedSagas.Saga

  step :CreateOrder
  step :CalculateShipping, skip_compensation: true
  step :ChargeCard
end
```

This will define Commands, Events and an aggregate for the Saga that works like this:

```elixir
iex> CheckoutSaga.execute(
...>   %CheckoutSaga{},
...>   %CheckoutSaga.Commands.StartSaga{saga_id: "id", data: %{some: :data}}
...> )
[
  %CheckoutSaga.Events.SagaStarted{saga_id: "id", data: %{some: :data}}
  %CheckoutSaga.Events.CreateOrderStarted{saga_id: "id", data: %{some: :data}}
]

iex> CheckoutSaga.execute(
...>   saga_after_create_order_started,
...>   %CheckoutSaga.Commands.FinishCreateOrder{saga_id: "id", data: %{other: :data}}
...> )
[
  %CheckoutSaga.Events.CreateOrderFinished{saga_id: "id", data: %{some: :data, other: :data}},
  %CheckoutSaga.Events.CalculateShippingStarted{saga_id: "id", data: %{some: :data, other: :data}}
]

iex> CheckoutSaga.execute(
...>   saga_after_create_order_started,
...>   %CheckoutSaga.Commands.FailCreateOrder{saga_id: "id", data: %{}}
...> )
[
  %CheckoutSaga.Events.CreateOrderFailed{saga_id: "id", data: %{some: :data}},
  %CheckoutSaga.Events.CreateOrderCompensationStarted{saga_id: "id", data: %{some: :data}}
]

iex> CheckoutSaga.execute(
...>   saga_after_create_order_compensation_started,
...>   %CheckoutSaga.Commands.FinishCreateOrderCompensation{saga_id: "id", data: %{}}
...> )
[
  %CheckoutSaga.Events.CreateOrderCompensationFinished{saga_id: "id", data: %{some: :data}},
  %CheckoutSaga.Events.SagaFailed{saga_id: "id"}
]
```

That is, for each step it generates

- `Finish{STEP}` command
- `Fail{STEP}` command
- `Finish{STEP}Compensation` command
- `{STEP}Started` event
- `{STEP}Finished` event
- `{STEP}Failed` event
- `{STEP}CompensationStarted` event
- `{STEP}CompensationFinished` event

### Configuring command router

```elixir
defmodule Router do
  use Commanded.Router

  dispatch(
    CheckoutSaga.all_commands,
    CheckoutSaga.dispatch_config("checkout-saga-")
  )

  # That is the same as
  dispatch(
    [
      CheckoutSaga.Commands.StartSaga,
      CheckoutSaga.Commands.FinishCreateOrder,
      CheckoutSaga.Commands.FailCreateOrder,
      CheckoutSaga.Commands.FinishCreateOrderCompensation,
      CheckoutSaga.Commands.FinishCalculateShipping
      # ...
      CheckoutSaga.Commands.FinishChargeCardCompensation
    ]
  )
end
```

### Implementing glue code

Now, let's suppose that:

1. `CreateOrder` is just an internal command
1. `CalculateShipping` is a sync external call
1. `ChargeCard` is an async external operation

Now this is how we could implement the glue code (later we may provide macros for these things)

#### CreateOrder: Local Command/Events

```elixir
defmodule CheckoutSaga.CreateOrder do
  use Commanded.ProcessManagers.ProcessManager, name: "CheckoutSaga.CreateOrder"

  alias CheckoutSaga.Events.{CreateOrderStarted, CreateOrderFinished, CreateOrderFailed}
  alias CheckoutSaga.Commands.{FinishCreateOrder, FailCreateOrder}
  alias Orders.Commands.CreateOrder
  alias Orders.Events.OrderCreated

  def interested?(%CreateOrderStarted{saga_id: id}), do: {:start, id}
  def interested?(%CreateOrderFinished{saga_id: id}), do: {:stop, id}
  def interested?(%CreateOrderFailed{saga_id: id}), do: {:stop, id}
  def interested?(%OrderCreated{id: id}), do: {:continue, id}

  defstruct []

  def handle(_, %CreateOrderStarted{saga_id: saga_id, data: my_data}) do
    %CreateOrder{
      id: saga_id,
      items: my_data.items
    }
  end

  def handle(_, %OrderCreated{} = evt) do
    %FinishCreateOrder{saga_id: evt.id}
  end

  def error(%CreateOrder{id: id}, _, _) do
    %FailCreateOrder{saga_id: id}
  end
end
```

#### CalculateShipping: External and Synchronous

```elixir
defmodule CheckoutSaga.CalculateShipping do
  use Commanded.ProcessManagers.ProcessManager, name: "CheckoutSaga.CalculateShipping"

  alias CheckoutSaga.Events.{CalculateShippingStarted, CalculateShippingFinished, CalculateShippingFailed}
  alias CheckoutSaga.Commands.{FinishCalculateShipping, FailCalculateShipping}

  def interested?(%CalculateShippingStarted{saga_id: id}), do: {:start, id}
  def interested?(%CalculateShippingFinished{saga_id: id}), do: {:stop, id}
  def interested?(%CalculateShippingFailed{saga_id: id}), do: {:stop, id}

  defstruct []

  def handle(_, %CalculateShippingStarted{saga_id: saga_id, data: data}) do
    case ShippingService.calculate_shipping(data.items) do
      {:ok, shipping_price} ->
        # Data by default will be merged with `Map.merge/1`
        %FinishCalculateShipping{saga_id: saga_id, data: %{shipping_price: shipping_price}}
      _ ->
        %FailCalculateShipping{saga_id: saga_id}
    end
  end
end
```

#### ChargeCard: External and Asynchronous

```elixir
defmodule CheckoutSaga.ChargeCard do
  use Commanded.Event.Handler, name: "CheckoutSaga.ChargeCard"

  alias CheckoutSaga.Events.ChargeCardStarted

  def handle(%ChargeCardStarted{saga_id: saga_id, data: data}, _) do
    :ok = PaymentService.charge_card(%{
      card: data.card_id,
      amount: data.price + data.shipping_price,
      idempotency_key: saga_id
    })
  end
end

# ... Somewhere else in your code

def handle_payment_service_event(%{type: :charge_accepted, idempotency_key: id}) do
  Router.dispatch(%CheckoutSaga.Commands.FinishChargeCard{saga_id: id})
end
def handle_payment_service_event(%{type: :charge_declined, idempotency_key: id}) do
  Router.dispatch(%CheckoutSaga.Commands.FaileChargeCard{saga_id: id})
end
```

#### Compensations

You also have to define the code for compensations

```elixir
defmodule CheckoutSaga.CreateOrderCompensation do
  use Commanded.ProcessManagers.ProcessManager, name: "CheckoutSaga.CreateOrderCompensation"

  alias CheckoutSaga.Events.{CreateOrderCompensationStarted, CreateOrderCompensationFinished}
  alias CheckoutSaga.Commands.FinishCreateOrderCompensation
  alias Orders.Commands.FailOrder
  alias Orders.Events.OrderFailed

  def interested?(%CreateOrderCompensationStarted{saga_id: id}), do: {:start, id}
  def interested?(%CreateOrderCompensationFinished{saga_id: id}), do: {:stop, id}
  def interested?(%OrderFailed{id: id}), do: {:continue, id}

  defstruct []

  def handle(_, %CreateOrderCompensationStarted{saga_id: saga_id}) do
    %FailOrder{id: saga_id}
  end

  def handle(_, %OrderFailed{} = evt) do
    %FinishCreateOrderCompensation{saga_id: evt.id}
  end
end
```

## Some notes

To be honest, this is not the best example. To be honest, you shouldn't have many local executions
as this is an indication that you probably are mixing the responsibilities of the saga and your
`Order` aggregate.

The domain probably would look like

```elixir
  step :CalculateShipping, skip_compensation: true
  step :ChargeCard
  step :PrepareShipping
  step :ShipItems
```

And then I'd build a View Model for the order with the corresponding state of the order.

## Extra Macro Ideas

### ProcessManager macro for Internal EventDriven

To avoid all the boilerplate when using process managers, I was thinking about the following macro:

```elixir
defmodule CheckoutSaga.CreateOrder do
  use CheckoutSaga.Step.CreateOrder.EventDriven, router: Router

  alias Orders.Events.OrderCreated
  alias Orders.Commands.CreateOrder

  def on_started(saga_id, data) do
    %CreateOrder{
      id: saga_id,
      items: data.items
    }
  end

  def finish_on(%OrderCreated{id: id}), do: id
  # And in case it is a event-driven failure
  def fail_on(%OrderFailed{id: id}), do: id
end
```

### ProcessManager macro for external synchronous

```elixir
defmodule CheckoutSaga.CalculateShipping do
  use CheckoutSaga.Step.CreateOrder.Synchronous, router: Router

  # This should return either `:finish`, `:fail`, `{:finish, data}`, `{:fail, data}`
  def execute(saga_id, data) do
    case ShippingService.calculate_shipping(data.items) do
      {:ok, shipping_price} ->
        {:finish, %{shipping_price: shipping_price}}
      _ ->
        :fail
    end
  end
end
```

## Installation

```elixir
def deps do
  [
    {:commanded_sagas, github: "bamorim/commanded_sagas"}
  ]
end
```