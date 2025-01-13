



# Harpoon

Use harpoon to quickly navigate to files in a project. It's like global marks, but it always saves when needed and it is on a per-project basis.


## Installation

```lua
return {
  'ThePrimeagen/harpoon',
  branch = 'harpoon2',
  dependencies = { 'nvim-lua/plenary.nvim' },
```


## Telescope integration

Use telescope UI and keymaps to navigate through harpoon files.

```lua
config = function()
  local harpoon = require 'harpoon'
  harpoon:setup {}
  local conf = require('telescope.config').values
  local function toggle_telescope(harpoon_files)
    local file_paths = {}
    for _, item in ipairs(harpoon_files.items) do
      table.insert(file_paths, item.value)
    end

    require('telescope.pickers')
      .new({}, {
        prompt_title = 'Harpoon',
        finder = require('telescope.finders').new_table {
          results = file_paths,
        },
        previewer = conf.file_previewer {},
        sorter = conf.generic_sorter {},
      })
      :find()
  end
```


## Keymaps

Some keymaps to interact with harpoon.

```lua
vim.keymap.set('n', '<leader>he', function()
  toggle_telescope(harpoon:list())
end, { desc = 'Open harpoon window' })

vim.keymap.set('n', '<leader>ha', function()
  harpoon:list():add()
end, { desc = 'Add current file to harpoon' })

vim.keymap.set('n', '<leader>hh', function()
  harpoon:list():select(1)
end, { desc = 'Select harpoon item 1' })

vim.keymap.set('n', '<leader>ht', function()
  harpoon:list():select(2)
end, { desc = 'Select harpoon item 2' })

vim.keymap.set('n', '<leader>hn', function()
  harpoon:list():select(3)
end, { desc = 'Select harpoon item 3' })

vim.keymap.set('n', '<leader>hs', function()
  harpoon:list():select(4)
end, { desc = 'Select harpoon item 4' })

-- Toggle previous & next buffers stored within Harpoon list
vim.keymap.set('n', '<leader>hrp', function()
  harpoon:list():prev()
end, { desc = 'Select previous harpoon item' })

vim.keymap.set('n', '<leader>hrn', function()
  harpoon:list():next()
end, { desc = 'Select next harpoon item' })
end,
}
```
