{{ config(
    alias = 'bot_trades',
    schema = 'bonkbot_solana',
    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    incremental_predicates = [incremental_predicate('DBT_INTERNAL_DEST.block_time')],
    unique_key = ['blockchain', 'tx_id', 'tx_index', 'outer_instruction_index', 'inner_instruction_index']
   )
}}

{% set project_start_date = '2023-08-17' %}
{% set fee_receiver = 'ZG98FUCjb8mJ824Gbs6RsgVmr1FhXb2oNiJHa2dwmPd' %}
{% set wsol_token = 'So11111111111111111111111111111111111111112' %}

WITH
  feePayments AS (
    SELECT DISTINCT
      tx_id,
      IF(balance_change > 0, 'SOL', 'SPL') AS feeTokenType,
      IF(
        balance_change > 0,
        balance_change / 1e9,
        token_balance_change
      ) AS fee_token_amount,
      IF(
        balance_change > 0,
        '{{wsol_token}}',
        token_mint_address
      ) AS fee_token_mint_address
    FROM
      {{ source('solana','account_activity') }}
    WHERE
      {% if is_incremental() %}
      {{ incremental_predicate('block_time') }}
      {% else %}
      block_time >= TIMESTAMP '{{project_start_date}}'
      {% endif %}
      AND tx_success
      AND (
        (
          address = '{{fee_receiver}}'
          AND balance_change > 0 -- SOL fee payments
        )
        OR (
          token_balance_owner = '{{fee_receiver}}'
          AND token_balance_change > 0 -- SPL fee payments
        )
      )
  ),
  -- Eliminate duplicates (e.g. both SOL + WSOL in a single transaction)
  allFeePayments AS (
    SELECT
      tx_id,
      MIN(feeTokenType) AS feeTokenType,
      SUM(fee_token_amount) AS fee_token_amount,
      fee_token_mint_address
    FROM
      feePayments
    GROUP BY
      tx_id,
      fee_token_mint_address
  ),
  solFeePayments AS (
    SELECT 
      * 
    FROM 
      allFeePayments 
    WHERE 
      feeTokenType = 'SOL'
  ),
  splFeePayments AS (
    SELECT 
      * 
    FROM 
      allFeePayments 
    WHERE 
      feeTokenType = 'SPL'
  ),
  -- Eliminate duplicates (e.g. both SOL + SPL payment in a single transaction)
  allFeePaymentsWithSOLPaymentPreferred AS (
    SELECT 
      COALESCE(solFeePayments.tx_id, splFeePayments.tx_id) AS tx_id,
      COALESCE(solFeePayments.feeTokenType, splFeePayments.feeTokenType) AS feeTokenType,
      COALESCE(solFeePayments.fee_token_amount, splFeePayments.fee_token_amount) AS fee_token_amount,
      COALESCE(solFeePayments.fee_token_mint_address, splFeePayments.fee_token_mint_address) AS fee_token_mint_address
    FROM
      solFeePayments 
      FULL JOIN splFeePayments ON solFeePayments.tx_id = splFeePayments.tx_id
  ),
  botTrades AS (
    SELECT
      trades.block_time,
      CAST(date_trunc('day', trades.block_time) AS date) AS block_date,
      CAST(date_trunc('month', trades.block_time) AS date) AS block_month,
      'solana' AS blockchain,
      amount_usd,
      IF(
        token_sold_mint_address = '{{wsol_token}}',
        'Buy',
        'Sell'
      ) AS type,
      token_bought_amount,
      token_bought_symbol,
      token_bought_mint_address AS token_bought_address,
      token_sold_amount,
      token_sold_symbol,
      token_sold_mint_address AS token_sold_address,
      fee_token_amount * price AS fee_usd,
      fee_token_amount,
      IF(feeTokenType = 'SOL', 'SOL', symbol) AS fee_token_symbol,
      fee_token_mint_address AS fee_token_address,
      project,
      trades.version,
      token_pair,
      project_program_id AS project_contract_address,
      trader_id AS user,
      trades.tx_id,
      tx_index,
      outer_instruction_index,
      inner_instruction_index
    FROM
      {{ ref('dex_solana_trades') }} AS trades
      JOIN allFeePaymentsWithSOLPaymentPreferred AS feePayments ON trades.tx_id = feePayments.tx_id
      LEFT JOIN {{ source('prices', 'usd') }} AS feeTokenPrices ON (
        feeTokenPrices.blockchain = 'solana'
        AND fee_token_mint_address = toBase58 (feeTokenPrices.contract_address)
        AND date_trunc('minute', block_time) = minute
        {% if is_incremental() %}
        AND {{ incremental_predicate('minute') }}
        {% else %}
        AND minute >= TIMESTAMP '{{project_start_date}}'
        {% endif %}
      )
      JOIN {{ source('solana','transactions') }} AS transactions ON (
        trades.tx_id = id
        {% if is_incremental() %}
        AND {{ incremental_predicate('transactions.block_time') }}
        {% else %}
        AND transactions.block_time >= TIMESTAMP '{{project_start_date}}'
        {% endif %}
      )
    WHERE
      trades.trader_id != '{{fee_receiver}}' -- Exclude trades signed by FeeWallet
      AND transactions.signer != '{{fee_receiver}}' -- Exclude trades signed by FeeWallet
      {% if is_incremental() %}
      AND {{ incremental_predicate('trades.block_time') }}
      {% else %}
      AND trades.block_time >= TIMESTAMP '{{project_start_date}}'
      {% endif %}
  ),
  highestInnerInstructionIndexForEachTrade AS (
    SELECT
      tx_id,
      outer_instruction_index,
      MAX(inner_instruction_index) AS highestInnerInstructionIndex
    FROM
      botTrades
    GROUP BY
      tx_id,
      outer_instruction_index
  )
SELECT
  block_time,
  block_date,
  block_month,
  'BonkBot' as bot,
  blockchain,
  amount_usd,
  type,
  token_bought_amount,
  token_bought_symbol,
  token_bought_address,
  token_sold_amount,
  token_sold_symbol,
  token_sold_address,
  fee_usd,
  fee_token_amount,
  fee_token_symbol,
  fee_token_address,
  project,
  version,
  token_pair,
  project_contract_address,
  user,
  botTrades.tx_id,
  tx_index,
  botTrades.outer_instruction_index,
  COALESCE(inner_instruction_index, 0) AS inner_instruction_index,
  IF(
    inner_instruction_index = highestInnerInstructionIndex,
    true,
    false
  ) AS is_last_trade_in_transaction
FROM
  botTrades
  JOIN highestInnerInstructionIndexForEachTrade ON (
    botTrades.tx_id = highestInnerInstructionIndexForEachTrade.tx_id
    AND botTrades.outer_instruction_index = highestInnerInstructionIndexForEachTrade.outer_instruction_index
  )
ORDER BY
  block_time DESC,
  tx_index DESC,
  outer_instruction_index DESC,
  inner_instruction_index DESC
