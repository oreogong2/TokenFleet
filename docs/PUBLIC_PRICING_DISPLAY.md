# 网页已有金额与计价覆盖率

网页通过两个只读入口显示已有公开估算：

- `/api/v1/public/priced-leaderboard`
- `/api/v1/public/priced-members/{public_id}`

过滤、可见性、限流、缓存与原公开接口一致。新增的 totals 字段是
`priced_tokens` 和按币种分别返回的 `priced_costs_microunits`，不返回私有价格
或内部用量桶数量。覆盖率按输入、输出、缓存读、缓存写四类 Token 合计计算，
不是估算准确度，也不是实付账单。

完整计价显示估算金额；部分计价显示已有金额和覆盖率；全部缺价显示未定价。
真实零费用与缺价区分，多币种不直接相加。费用排名仍只比较完整、同币种的金额。

原公开接口及设备接口的字段、排名和金额语义保留。旧客户端不需要升级；
网页遇到新入口不存在时回退到原公开接口。这项改进不录入价格、不补算历史、
不改客户端、不迁移数据库。

验证入口：服务端 `tests/test_public_pricing_display.py` 覆盖公开边界、历史冻结、
旧 Windows 解析器兼容；网页运行 `npm test` 及 `python3 tests/pricing_browser.py`。
