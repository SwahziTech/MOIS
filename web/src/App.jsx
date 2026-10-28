import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider } from './hooks/useAuth';
import { ProtectedLayout, AuthLayout } from './components/Layout';
import Login        from './pages/auth/Login';
import Signup       from './pages/auth/Signup';
import ForgotPassword from './pages/auth/ForgotPassword';
import ResetPassword  from './pages/auth/ResetPassword';
import Dashboard    from './pages/Dashboard';
import Products     from './pages/Products';
import Materials    from './pages/Materials';
import Branches     from './pages/Branches';
import UsersPage    from './pages/Users';
import Recipes      from './pages/Recipes';
import Pricing      from './pages/Pricing';
import Settings     from './pages/Settings';
import Categories   from './pages/Categories';
import Colours      from './pages/Colours';
import ReviewQueue  from './pages/ReviewQueue';
import Suppliers    from './pages/Suppliers';
import Stock        from './pages/Stock';
import Movements    from './pages/Movements';
import StockImport  from './pages/StockImport';
import Approvals    from './pages/Approvals';
import Purchases    from './pages/Purchases';
import Production   from './pages/Production';
import ProductionLedger from './pages/ProductionLedger';
import Costing from './pages/Costing';
import Sales from './pages/Sales';
import Customers from './pages/Customers';
import SaleDocument from './pages/SaleDocument';
import StatementDocument from './pages/StatementDocument';
import PurchaseOrderDocument from './pages/PurchaseOrderDocument';
import WeeklyCash from './pages/WeeklyCash';
import Staff from './pages/Staff';

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          {/* Auth routes (redirect to / if already signed in) */}
          <Route element={<AuthLayout />}>
            <Route path="/login"           element={<Login />} />
            <Route path="/signup"          element={<Signup />} />
            <Route path="/forgot-password" element={<ForgotPassword />} />
          </Route>

          {/* The recovery link signs the user in, so this page must not sit
              under AuthLayout (which redirects signed-in users away). */}
          <Route path="/reset-password" element={<ResetPassword />} />

          {/* A sale's printable documents: a tab of their own, no sidebar (signed-in check inside) */}
          <Route path="/print/sale/:id" element={<SaleDocument />} />
          <Route path="/print/statement/:id" element={<StatementDocument />} />
          <Route path="/print/po/:id" element={<PurchaseOrderDocument />} />

          {/* Protected routes (redirect to /login if not signed in) */}
          <Route element={<ProtectedLayout />}>
            <Route index               element={<Dashboard />} />
            <Route path="/products"    element={<Products />} />
            <Route path="/categories"  element={<Categories />} />
            <Route path="/colours"     element={<Colours />} />
            <Route path="/review"      element={<ReviewQueue />} />
            <Route path="/approvals"   element={<Approvals />} />
            <Route path="/suppliers"   element={<Suppliers />} />
            <Route path="/stock"       element={<Stock />} />
            <Route path="/movements"   element={<Movements />} />
            <Route path="/purchases"   element={<Purchases />} />
            <Route path="/production"  element={<Production />} />
            <Route path="/production/ledger" element={<ProductionLedger />} />
            <Route path="/costing" element={<Costing />} />
            <Route path="/sales" element={<Sales />} />
            <Route path="/customers" element={<Customers />} />
            <Route path="/weekly-cash" element={<WeeklyCash />} />
            <Route path="/staff" element={<Staff />} />
            <Route path="/stock/import" element={<StockImport />} />
            <Route path="/materials"   element={<Materials />} />
            <Route path="/branches"    element={<Branches />} />
            <Route path="/users"       element={<UsersPage />} />
            <Route path="/recipes"     element={<Recipes />} />
            <Route path="/pricing"     element={<Pricing />} />
            <Route path="/settings"    element={<Settings />} />
          </Route>

          {/* Catch-all */}
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  );
}
