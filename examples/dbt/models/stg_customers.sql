select
  cast(customer_id as bigint) as customer_id,
  cast(customer_name as varchar) as customer_name,
  cast(email as varchar) as email,
  cast(created_at as timestamp) as created_at
from {{ ref('raw_customers') }}
