/**
 * @see https://theme-plume.vuejs.press/config/navigation/ 查看文档了解配置详情
 *
 * Navbar 配置文件，它在 `.vuepress/plume.config.ts` 中被导入。
 */

import { defineNavbarConfig } from 'vuepress-theme-plume'

export const zhNavbar = defineNavbarConfig([
  { text: '首页', link: '/' },
  { text: '下载', link: '/download/' },
  { text: '快速开始', link: '/quickstart/' },
  { text: '使用文档', link: '/docs/' },
  { text: '场景教程', link: '/tutorials/' },
  { text: '常见问题', link: '/faq/' },
  { text: '定价说明', link: '/pricing/' },
])
