{{config(
        alias = 'balancer_gauges',
        post_hook='{{ expose_spells(\'["ethereum", "arbitrum", "optimism", "polygon", "avalanche_c", "base", "gnosis", "zkevm"]\',
                                    "sector",
                                    "labels",
                                    \'["jacektrocinski", "viniabussafi"]\') }}')}}

{% set gauges_models = [
    ref('labels_balancer_gauges_ethereum')
    , ref('labels_balancer_gauges_polygon')
    , ref('labels_balancer_gauges_arbitrum')
    , ref('labels_balancer_gauges_optimism')
    , ref('labels_balancer_gauges_avalanche_c')
    , ref('labels_balancer_gauges_base')        
    , ref('labels_balancer_gauges_gnosis')     
    , ref('labels_balancer_gauges_zkevm')           
] %}

SELECT *
FROM (
    {% for gauges_model in gauges_models %}
    SELECT
          blockchain
         , address
         , pool_address
         , child_gauge_address
         , name
         , status
         , category
         , contributor
         , source
         , created_at
         , updated_at
         , model_name
         , label_type
    FROM {{ gauges_model }}
    {% if not loop.last %}
    UNION ALL
    {% endif %}
    {% endfor %}
)
