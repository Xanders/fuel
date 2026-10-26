module Fuel
  alias LeaderboardReader = Proc(DB::Connection, String, String, String, Int32, JSON::Any)

  class Store
    def leaderboard_page(connection : DB::Connection, actor : String, board : String, limit = 100) : JSON::Any
      Fuel.key(board)
      Fuel.check((1..100).includes?(limit), "invalid_limit")
      JSON.parse(connection.query_one(<<-SQL, @namespace, board, actor, limit, as: String))
        WITH ranked AS (
          SELECT account,name,score,row_number() OVER(ORDER BY score DESC,achieved_at,account) AS rank
          FROM fuel_scores WHERE ns=$1 AND board=$2
        ), page AS (
          SELECT rank::text,name,score::text,account=$3 AS is_player
          FROM ranked ORDER BY rank LIMIT $4
        )
        SELECT json_build_object(
          'entries',COALESCE((SELECT json_agg(row_to_json(page) ORDER BY rank::bigint) FROM page),'[]'::json),
          'player_rank',(SELECT rank::text FROM ranked WHERE account=$3),
          'player_best',(SELECT score::text FROM ranked WHERE account=$3))::text
        SQL
    end
  end
end
