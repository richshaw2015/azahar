// Nintendo 3DS CFG country code index (0-186) -> ISO 3166-1 alpha-2。
// 与 src/core/hle/service/cfg/cfg.cpp 的 country_codes 表一一对应，空串为无效槽位。
export const COUNTRY_ISO_CODES: string[] = [
  '', 'JP', '', '', '', '', '', '', 'AI', 'AG', 'AR', 'AW',
  'BS', 'BB', 'BZ', 'BO', 'BR', 'VG', 'CA', 'KY', 'CL', 'CO', 'CR', 'DM',
  'DO', 'EC', 'SV', 'GF', 'GD', 'GP', 'GT', 'GY', 'HT', 'HN', 'JM', 'MQ',
  'MX', 'MS', 'AN', 'NI', 'PA', 'PY', 'PE', 'KN', 'LC', 'VC', 'SR', 'TT',
  'TC', 'US', 'UY', 'VI', 'VE', '', '', '', '', '', '', '',
  '', '', '', '', 'AL', 'AU', 'AT', 'BE', 'BA', 'BW', 'BG', 'HR',
  'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR', 'HU', 'IS', 'IE', 'IT',
  'LV', 'LS', 'LI', 'LT', 'LU', 'MK', 'MT', 'ME', 'MZ', 'NA', 'NL', 'NZ',
  'NO', 'PL', 'PT', 'RO', 'RU', 'RS', 'SK', 'SI', 'ZA', 'ES', 'SZ', 'SE',
  'CH', 'TR', 'GB', 'ZM', 'ZW', 'AZ', 'MR', 'ML', 'NE', 'TD', 'SD', 'ER',
  'DJ', 'SO', 'AD', 'GI', 'GG', 'IM', 'JE', 'MC', 'TW', '', '', '',
  '', '', '', '', 'KR', '', '', '', '', '', '', '',
  'HK', 'MO', '', '', '', '', '', '', 'ID', 'SG', 'TH', 'PH',
  'MY', '', '', '', 'CN', '', '', '', '', '', '', '',
  'AE', 'IN', 'EG', 'OM', 'QA', 'KW', 'SA', 'SY', 'BH', 'JO', '', '',
  '', '', '', '', 'SM', 'VA', 'BM'
];
