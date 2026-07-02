select
  o.customer_id,
  count(*) as order_count,
  sum(o.amount) as total_amount
from {{ ref('stg_orders') }} o
group by 1
