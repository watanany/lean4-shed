select
  cast(order_id as bigint) as order_id,
  cast(customer_id as bigint) as customer_id,
  cast(status as varchar) as status,
  cast(amount as double) as amount,
  cast(ordered_at as timestamp) as ordered_at
from {{ ref('raw_orders') }}
