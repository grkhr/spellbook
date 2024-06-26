{{
  config(
    alias='ccip_request_daily',
    partition_by=['date_month'],
    materialized='incremental',
    file_format='delta',
    incremental_strategy='merge',
    unique_key=['date_start']
  )
}}


WITH
ethereum_agg AS (
        SELECT
            date_start,
            (
                SELECT
                    COUNT(*)
                FROM
                    {{ ref('chainlink_bnb_ccip_fulfilled_transactions') }} eth
                WHERE
                    eth.date_start = date_series.date_start
                {% if is_incremental() %}
                    AND {{ incremental_predicate('eth.block_time') }}
                {% endif %}
            ) AS fulfilled_requests,
            (
                SELECT
                    COUNT(*)
                FROM
                    {{ ref('chainlink_bnb_ccip_reverted_transactions') }} rev
                WHERE
                    rev.date_start = date_series.date_start
                {% if is_incremental() %}
                    AND {{ incremental_predicate('rev.block_time') }}
                {% endif %}
            ) AS reverted_requests
        FROM
            (
                SELECT
                    date_start
                FROM
            (
                SELECT
                    sequence (
                        CAST('2023-07-06' AS date),
                        date_trunc ('day', cast(now () AS date)),
                        INTERVAL '1' day
                    ) AS date_sequence
            ) AS seq
            CROSS JOIN UNNEST (seq.date_sequence) AS t (date_start)
            {% if is_incremental() %}
                    WHERE {{ incremental_predicate('date_start') }}
            {% endif %}
            ) date_series
    ),
    ccip_request_daily as (
        SELECT
            'bnb' as blockchain,
            cast(date_trunc('month', date_start) as date) as date_month,
            date_start,
            fulfilled_requests,
            reverted_requests,
            fulfilled_requests + reverted_requests AS total_requests
        FROM
            ethereum_agg
    )
SELECT
  ccip_request_daily.blockchain,
  date_start,
  date_month,
  fulfilled_requests,
  reverted_requests,
  total_requests
FROM
  ccip_request_daily
ORDER BY
  "date_start"