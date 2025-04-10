import akshare as ak

df = stock_sh_a_spot_em_df = ak.stock_sh_a_spot_em()

# 筛选市值小于50亿且市净率大于0的股票
small_cap = df[(df['流通市值'] > 10e8) & (df['流通市值'] < 30e8) & (df['市盈率-动态'] > 500)]  # 5e8表示5亿市值，使用&连接条件

print(small_cap)


