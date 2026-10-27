import Modal from '../Modal';
import { useAuth } from '../../hooks/useAuth';
import { RejectReasonsCard, CuringDays, MinCuringDays } from '../settings/PurchaseSettings';
import ProductionTeamsCard from '../settings/ProductionTeamsCard';
import CasualDayRateCard from '../settings/CasualDayRateCard';

/**
 * Production settings (2026-10-25, the user: "the production settings
 * should be on the production page") — opened from the ⚙ beside the
 * Production heading: curing, reject reasons, teams and machines, the casual day rate (073).
 */
export default function ProductionSettings({ onClose }) {
  const { canManage } = useAuth();
  return (
    <Modal title="Production settings" onClose={onClose} size="lg"
      footer={<button type="button" className="btn btn-outline" onClick={onClose}>Close</button>}>
      <div className="ps-grid">
        <section className="card">
          <div className="card-header"><h2 className="card-title">Curing</h2></div>
          <div className="card-body" style={{ paddingTop: 6 }}>
            <div className="ps-row"><span>Curing period</span><CuringDays canEdit={canManage('org.manage')} /></div>
            <div className="ps-row"><span>Minimum curing</span><MinCuringDays canEdit={canManage('org.manage')} /></div>
          </div>
        </section>
        <ProductionTeamsCard />
        <CasualDayRateCard />
        <RejectReasonsCard />
      </div>
    </Modal>
  );
}
