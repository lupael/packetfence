import store from '@/store'
import UsersView from '../'
import UsersStore from '../_store'

const UsersSearch = () => import(/* webpackChunkName: "Users" */ '../_components/UsersSearch')
const UsersCreate = () => import(/* webpackChunkName: "Users" */ '../_components/UsersCreate')
const UsersPreview = () => import(/* webpackChunkName: "Users" */ '../_components/UsersPreview')
const UserView = () => import(/* webpackChunkName: "Users" */ '../_components/UserView')
const UsersImport = () => import(/* webpackChunkName: "Editor" */ '../_components/UsersImport')

const route = {
  path: '/users',
  name: 'users',
  redirect: '/users/search',
  component: UsersView,
  props: { storeName: '$_users' },
  meta: { transitionDelay: 300 * 2 }, // See _transitions.scss => $slide-bottom-duration
  beforeEnter: (to, from, next) => {
    if (!store.state.$_users) {
      // Register store module only once
      store.registerModule('$_users', UsersStore)
    }
    next()
  },
  children: [
    {
      path: 'search',
      component: UsersSearch,
      props: (route) => ({ storeName: '$_users', query: route.query.query }),
      meta: {
        can: 'read users',
        fail: { path: '/configuration', replace: true }
      }
    },
    {
      path: 'create',
      component: UsersCreate,
      props: { storeName: '$_users' },
      meta: {
        can: 'create users'
      }
    },
    {
      path: 'import',
      component: UsersImport,
      props: { storeName: '$_users' },
      meta: {
        can: 'create users'
      }
    },
    {
      path: 'preview',
      name: 'usersPreview',
      component: UsersPreview,
      props: { storeName: '$_users' },
      meta: {
        can: 'create users'
      }
    },
    {
      path: '/user/:pid',
      name: 'user',
      component: UserView,
      props: (route) => ({ storeName: '$_users', pid: route.params.pid }),
      beforeEnter: (to, from, next) => {
        store.dispatch('$_users/getUser', to.params.pid).then(user => {
          next()
        })
      },
      meta: {
        can: 'read users'
      }
    }
  ]
}

export default route